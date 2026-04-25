# План реализации Blender-style Edge Bevel в Vibe3D

Источник алгоритма: `doc/blender_edge_bevel.md`.
Текущий код: `source/tools/bevel.d` (~910 строк, edge bevel занимает примерно половину).

## Что уже есть

Упрощённый edge bevel в `BevelTool`:
- Per-vertex обход через half-edge (`mesh.dartsAroundVertex`).
- На каждое инцидентное ребро вокруг beveled-вершины создаётся одна `BoundVert`.
- `slideDir = offsetInPlane(edgeDir, faceNormal)` — упрощение, без пересечения offset-прямых.
- `ebWidth` — общий скаляр; `pos = origPos + slideDir * ebWidth`.
- На каждое beveled-ребро строится один квад `[bvA_F1, bvB_F1, bvB_F2, bvA_F2]`.
- Cap-полигон закрывает вершину (`capPoly`).
- Snapshot/revert для интерактивного drag.
- Тест: `tests/test_bevel.d` — bevel одного ребра куба → 10v/15e/7f.

Это примерно эквивалент Blender-овского `seg=1, M_POLY` без `offset_meet`,
без режимов ширины, без профиля, без подразбиения, без miter / terminal /
pipe / cube-corner спецкейсов.

## Чего нет — list to deliver

1. Структуры `BevVert` / `EdgeHalf` / `BoundVert` / `Profile` / `VMesh`.
2. Корректный `offset_meet` (пересечение offset-прямых соседей).
3. Per-side offsets (`offset_l` / `offset_r`).
4. Режимы ширины OFFSET / WIDTH / DEPTH / PERCENT.
5. Профили с N сегментами (суперэллипс).
6. `M_ADJ` через Catmull-Clark подразбиение.
7. Least-squares выравнивание ширин.
8. Спецкейсы: weld / terminal / pipe / cube-corner / miter.
9. Корректный `bev_rebuild_polygon`.
10. `limit_offset`, custom profile curve, vertex-only bevel.

---

## Этапы

Каждый этап = отдельный коммит, проходящий `./run_test.sh`. Тесты живут в
`tests/test_bevel*.d` и используют HTTP API (`/api/reset`,
`/api/play-events`, `/api/model`, `/api/selection`).

### Этап 1 — Каркас данных (рефакторинг без смены поведения)

**Делать.** Создать модуль `source/bevel.d` со структурами:

```d
struct EdgeHalf {
    uint  edgeIdx;          // в mesh.edges
    uint  vert;             // BevVert-вершина, к которой относится этот half
    bool  isReversed;       // edges[edgeIdx][0] != vert
    bool  isBev;            // ребро в selection
    float offsetLSpec, offsetRSpec; // ввод от пользователя (через width-mode)
    float offsetL,     offsetR;     // фактические после adjust
    int   leftBV, rightBV;  // индексы в BevVert.boundVerts
    uint  fprev, fnext;     // соседние face-индексы (или ~0u)
}

struct Profile {
    Vec3   start, middle, end;
    Vec3   planeNormal;
    float  superR = 2.0f;   // 2 = окружность, 1 = прямая
    Vec3[] sample;          // готовые seg+1 точек
}

enum VMeshKind { POLY, ADJ, TRI_FAN, CUTOFF }

struct BoundVert {
    Vec3    pos;
    int     ehFromIdx, ehToIdx;
    Profile profile;        // от этой BoundVert до следующей по кругу
    bool    isOnEdge;
    int     vertId;         // индекс в mesh.vertices после материализации
}

struct VMesh {
    VMeshKind kind;
    int       seg;
    int[]     gridVerts;    // (count × (seg/2+1) × (seg+1)), индексы в mesh.vertices
}

struct BevVert {
    uint        vert;
    EdgeHalf[]  edges;      // CCW
    int         selCount;
    BoundVert[] boundVerts; // циклический список
    VMesh       vmesh;
}
```

Переписать `applyEdgeBevelTopology` через `BevVert` + `EdgeHalf`, но
сохранить точное поведение текущего этапа (`seg=1`, `kind=POLY`,
slide-вычисление как сейчас).

**Проверка.** `./run_test.sh` — `test_bevel.d` проходит без изменений.
Топология куба после bevel: 10v / 15e / 7f.

### Этап 2 — `bevel_vert_construct` (формализация сбора BevVert)

**Делать.** Вынести построение `BevVert` в отдельную функцию
`buildBevVert(mesh, vert, selectedEdges) → BevVert` в `bevel.d`:
- Собрать `EdgeHalf` в CCW-порядке через `dartsAroundVertex`.
- Заполнить `fprev`/`fnext` (грани из `loops[dart].face` и
  `loops[loops[dart].twin].face`).
- Посчитать `selCount`.

**Проверка.** Новый юнит-тест `tests/test_bevel_bevvert.d`:
- На кубе с одним выбранным ребром у двух BevVert валентность = 3,
  selCount = 1.
- Все `EdgeHalf.fprev` / `fnext` указывают на разные face-индексы.
- Для последовательных EdgeHalf совпадают: `e[i].fnext == e[i+1].fprev`.

### Этап 3 — `offset_meet` (нормальный случай)

**Делать.** Заменить per-face `offsetInPlane(edgeDir, fNorm) * ebWidth`
на пересечение offset-прямых пары соседних `EdgeHalf`:

```
offsetMeet(BevVert bv, eIdx1, eIdx2):
  faceN = faceNormal(commonFace(e1, e2))
  L1: p1 + t*dir(e1),  p1 = origPos + offsetInPlane(-dir(e1), faceN)*e1.offsetL
  L2: p2 + s*dir(e2),  p2 = origPos + offsetInPlane( dir(e2), faceN)*e2.offsetR
  пересечение L1 ∩ L2 в плоскости грани → BoundVert.pos
  fallback: параллельные / антипараллельные → среднее p1, p2
```

В `math.d` уже есть похожий код (см. `offsetInPlane`, lines ~317–328) —
обобщить до полноценного intersect.

Случаи:
- Оба `isBev` → стандартный meet.
- Один не `isBev` → BoundVert едет вдоль самого небевелируемого
  ребра (`offset_on_edge`).
- Оба не `isBev` → BoundVert не нужен.

**Проверка.** Тест `test_bevel_offset_meet.d`:
- Куб, ребро по оси X beveled с w=0.1 → BoundVerts в концах
  должны лежать на расстоянии 0.1 от исходной вершины вдоль каждого
  из двух соседних рёбер (Y-edge и Z-edge), точность 1e-5.
- Два смежных ребра на одной грани beveled, угол 90° → общая BoundVert
  на расстоянии 0.1 от обоих рёбер.
- Сравнение через HTTP `/api/model`.

### Этап 4 — Режимы ширины

**Делать.** Enum `BevelWidthMode { Offset, Width, Depth, Percent }` в UI
(radio button, `drawProperties`).

В `BevVert::computeOffsetSpecs(mode, w)`:
```
OFFSET:  offsetSpec = w
WIDTH:   offsetSpec = w / (2 * sin(dihedral/2))
DEPTH:   offsetSpec = w / cos(dihedral/2)
PERCENT: offsetSpec = edgeLength * w / 100
```

Где `dihedral = angle(faceNormal(fprev), faceNormal(fnext))` (по ребру).

**Проверка.** `test_bevel_width_modes.d`. На кубе (90° dihedral):
- WIDTH=1 → фактический offset = 1 / (2·sin 45°) = √2/2 ≈ 0.7071.
- DEPTH=1 → offset = 1 / cos 45° = √2 ≈ 1.4142.
- PERCENT=50 → offset = 0.5 (рёбра единичной длины).
Сверка координат через `/api/model`.

### Этап 5 — Per-side offsets

**Делать.** Расщепить общий `width` на `offsetLSpec` / `offsetRSpec`. UI:
checkbox «asymmetric», при включении показываются два поля. По умолчанию
`offsetL == offsetR`. В `offsetMeet` использовать `e1.offsetR` (правая
сторона e1 = левая сторона e2 относительно общей грани) и `e2.offsetL`.

**Проверка.** `test_bevel_asymmetric.d`. `offsetL=0.1, offsetR=0.3` на
ребре куба → BoundVerts смещены асимметрично, расстояния от ребра до
двух BoundVerts на разных гранях равны 0.1 и 0.3.

### Этап 6 — Профиль и сегменты

**Делать.**
- Параметр `seg` (1..16), UI slider.
- Для каждой `BoundVert.profile`:
  - `start` = pos этой BoundVert.
  - `end` = pos следующей по кругу BoundVert.
  - `middle` = пересечение нессдвинутых рёбер (исходная вершина `bv.vert`).
  - `planeNormal` = сумма нормалей соседних граней.
- `make_unit_square_map(start, middle, end, normal)` — из `bmesh_bevel.cc`.
- Сэмплирование суперэллипса:
  ```
  для t ∈ [0,1] (seg+1 точек):
      (u, v) на единичной четверть-окружности в нормированных координатах
      pt = unitMap(u, v)
  super_r = 2 → круг, super_r = 1 → прямая, super_r = 4 → ближе к квадрату
  ```
- Материализация: при `seg=1` — два BoundVert (как сейчас); при `seg≥2`
  по `seg-1` дополнительных вершин на профиле + квад-полоса вдоль ребра.

VMesh kind:
- `seg=1` → `M_POLY`.
- `selCount=1` → `M_TRI_FAN`.
- иначе → `M_ADJ` (этап 7).

**Проверка.** `test_bevel_profile.d`:
- `seg=4`, w=0.1 на ребре куба → cap-полигон состоит из `2 * (seg+1)`
  вершин на профильной кривой.
- При `super_r=2` все sample-точки на расстоянии w от исходной вершины
  (четверть окружности r=w в плоскости пары рёбер), точность 1e-4.

### Этап 7 — `M_ADJ` через Catmull-Clark

**Делать.** Для `selCount ≥ 3`:
1. Грубая сетка при `seg_init = 2`: `N` BoundVerts по периметру + 1
   центральная вершина (через «fullness» — взвешенная сумма BoundVert.pos
   и pull-к-исходной вершине).
2. Catmull-Clark подразбиение вдвое до `seg_target`. В `mesh.d` уже есть
   реализация для всего меша — извлечь ядро в `subdivideQuadPatch` или
   запустить локально на временном Mesh.
3. Если `seg_target` не степень двойки — финальная линейная интерполяция
   между двумя ближайшими subdivided-уровнями.

**Проверка.** `test_bevel_corner.d`:
- Cube corner (3 ребра, valence 3), `seg=4` → cap = 5×5 quad-сетка.
- Центральная точка лежит на нормали `(1,1,1)/√3` от исходной вершины
  на ожидаемой высоте.

### Этап 8 — Offset adjustment (least squares)

**Делать.**
- `offsetAdjust` checkbox.
- Построить граф зависимостей: `BoundVert`-ы на одном небевелируемом
  ребре (`eon`) связаны → их фактические ширины должны быть равны.
- Найти chains (открытые) и cycles (закрытые) в этом графе.
- Для каждой компоненты: min Σ(actualWidth_i − specWidth_i)² при условии
  равенства всех actualWidth → 1D LS, тривиальный.
- Применить новые `offsetL/R` и пересчитать `boundary`.

**Проверка.** `test_bevel_adjust.d`:
- Два смежных ребра куба с `widthSpec=0.1` и `widthSpec=0.3`,
  `adjust=true` → фактические ширины обоих ≈ 0.2 (среднее).

### Этап 9 — Спецкейсы (по одному коммиту)

**9a. Weld** — `selCount=2`, valence=2.
- Нет VMesh, два BoundVert из одного `BevVert` склеены через профили
  (одна кривая + её зеркало через `move_weld_profile_planes`).
- Тест: один beveled-ребро на «диске» из двух треугольников.

**9b. Terminal edge** — `selCount=1`, valence ≥ 3.
- 2–3 BoundVert вдоль небевелируемых рёбер (на расстоянии offset).
- VMesh kind = `M_TRI_FAN` (центральная вершина + треугольный веер).
- Тест: одно beveled-ребро, упирающееся в pole vertex.

**9c. Pipe** — `selCount=2`, два коллинеарных beveled.
- Профили совмещаются в одну дугу (snap к цилиндру).
- Тест: ребро, проходящее насквозь через 4 квада, beveled.

**9d. Cube corner** — `selCount=3`, три взаимно перпендикулярных beveled.
- Detect через `|dot(e_i, e_j)| < eps` для всех пар.
- Симметричная сетка: точки распределены по сферическому треугольнику.
- Тест: одна вершина куба, все три ребра beveled.

**9e. Miters (reflex / concave)** — dihedral > 180° или < 90°.
- Detect через знак `dot(faceN(fprev), edgeDir)` относительно нормы.
- Sharp / patch / arc miter — добавляются 1–3 дополнительных BoundVert.
- Тест: «Г-образный» меш с reflex-углом.

### Этап 10 — `bev_rebuild_polygon`

**Делать.** Сейчас исходная грань snapshot-ится и в ней одна вершина
заменяется на BoundVert (`mesh.faces[faceIdx]` patched in place). Это
ломается, когда у грани две / три beveled-вершины с многосегментными
профилями.

Заменить на полноценный обход:
1. Для каждой исходной грани F пройти её corner-ы.
2. В каждой beveled-вершине `bv` вставить последовательность профильных
   точек от BoundVert, относящейся к `prev_edge` в F, до BoundVert,
   относящейся к `next_edge` в F.
3. Сшить новые indices в новую грань F'.
4. Скопировать атрибуты (UV, sharp, seam) — заглушки, пока в Vibe3D
   нет per-corner данных.

**Проверка.** `test_bevel_rebuild.d`:
- Куб, beveled все 12 рёбер, `seg=2` → ожидаемая топология
  (24v `2×12` BoundVerts + 8 corner cap-mesh + 12 edge bands), точные
  числа выводятся из формулы; сравнение с эталонным дампом.

### Этап 11 — `limit_offset`, custom curve, vertex-only

- `limit_offset`: clamp `offsetL/R` так, чтобы actualWidth ≤
  0.5 · edgeLength соседнего ребра — предотвращает инверсию.
- Custom profile curve (CurveProfile-style редактор). Можно отложить.
- Vertex-only bevel: новый режим, без выделения рёбер; одна BoundVert
  на каждое инцидентное ребро вершины.

**Проверка.** `test_bevel_limit.d`: огромный width на маленьком ребре →
автоматический clamp, итоговый меш не имеет вывернутых полигонов
(все `faceNormal` указывают наружу).

---

## Риски и упрощения

- **UV / материалы.** В Vibe3D нет per-corner-атрибутов. UV-перенос —
  заглушка до этапа 10–11; не блокирует остальное.
- **Half-edge.** В `mesh.d` уже есть `loops` / `buildLoops` /
  `dartsAroundVertex` / `facesAroundEdge` — этого хватает на все обходы
  Blender-овского bevel.
- **Catmull-Clark.** Уже есть в `mesh.d` (на весь меш). Для VMesh —
  либо извлечь ядро в reusable-функцию, либо локально на временном
  `Mesh`-инстансе подразбить и слить обратно.
- **Тестируемость.** HTTP-API + recorded event-logs дают детерминизм.
  Каждый этап — отдельный `tests/test_bevel_*.d`, видимый из
  `run_test.sh`.

## Порядок коммитов

1. data scaffolding (этап 1)
2. bevel_vert_construct (этап 2)
3. offset_meet (этап 3)
4. width modes (этап 4)
5. per-side offsets (этап 5)
6. profile + segments (этап 6)
7. M_ADJ subdivision (этап 7)
8. offset adjust (этап 8)
9. spec cases — 5 коммитов (9a–9e)
10. polygon rebuild (этап 10)
11. limits / vertex-only / polish (этап 11)

Итого ~15 коммитов. Этапы 1–6 дают функционально ценный результат
(работающий single-segment bevel с правильными offset-ами и режимами
ширины); 7+ — это уже расширение для качества.
