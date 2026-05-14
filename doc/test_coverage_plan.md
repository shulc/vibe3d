# План тестового покрытия

_Обновлено 2026-05-14. Предыдущая версия плана (этапы 1–7) в основном
реализована: добавлены `test_select_topology`, `test_subdivide`,
`test_viewport_fit`, `test_file_io`, `test_http_command`,
`test_lasso_select`, `test_subpatch`, плюс `/api/command`, `/api/select`,
edges в `/api/model`. Этот документ — следующая итерация._

## Текущее состояние покрытия

**Хорошо покрыто** (~62 тестовых файла):
- Bevel: 12 файлов (edge / polygon / corner / profile / limit / width-modes / rebevel / asymmetric / capseg / bevvert / offset_meet / valence4)
- Примитивы: box / capsule / cone / cylinder / sphere / torus / pen
- Selection: HTTP + topology (loop, ring, expand, contract, more, less, between, connect, invert), Modo-совместимость, lasso
- Toolpipe state: ACEN / AXIS / ACTR / Falloff / Skeleton / Snap / Symmetry (все стейджи имеют тесты атрибутов)
- Camera, viewport.fit / fit_selected, file IO round-trip, undo / redo + history + refire
- Subdivide / subpatch (базовый toggle и move), delete, vert merge / join, vertex_edit
- HTTP endpoints, argstring parsing, deform presets, transform math (translate / rotate / scale)

**Слабо покрыто или не покрыто**:

| Категория              | Что есть                       | Что отсутствует                                       |
|------------------------|--------------------------------|-------------------------------------------------------|
| Tools (drag)           | math через `/api/transform`    | gizmo-arrow / cone drag через event-log               |
| Snap                   | состояние стейджа              | snap-to во время drag (захват элемента)               |
| Symmetry               | состояние стейджа              | parity-edit при drag вершин / граней                  |
| Falloff                | linear state                   | radial / screen / lasso drag, two-stage create        |
| Workplane (5 команд)   | —                              | **0 тестов**                                          |
| Subpatch               | базовый toggle через API       | Tab-toggle через event, performance regression        |
| Action-center widget   | команды                        | клики по виджету в viewport                           |
| Property panel         | —                              | drag слайдеров                                        |
| LWO format             | round-trip cube                | PTCH-чанки, рваные файлы, большие меши                |
| GPU select picker      | косвенно через picking         | прямые тесты ID-буфера, subpatch preview → cage       |
| Производительность     | —                              | **нет benchmark-suite** (есть только `doc/subpatch_drag_perf_log.md`) |

Событийных логов в `tests/events/` всего 19, и только 9 из 62 тестов
фактически проигрывают события (`play-events`). Остальные используют
HTTP-команды напрямую — отсюда «мало интерактивных тестов».

### Команды без тестов

Из всех команд под `source/commands/` явно не покрыты:
- `workplane.*` (5 команд: reset / edit / rotate / offset / alignToSelection)
- `file.new`, `file.quit`
- `history.show` (тестируются только undo / redo)
- `snap.toggleType` (есть только `snap.toggle`)

### Производительность

`source/visibility_cache.d`, `source/gpu_select.d`, `source/subpatch_osd.d`
(1797 строк!) — критичны по производительности. Документ
`doc/subpatch_drag_perf_log.md` фиксировал оптимизации, но
**автоматического regression-теста нет**.

---

## Предлагаемый план

Разбит на 5 этапов от наиболее ценного к нишевому. Каждый шаг = 1
коммит. Указано, что добавить и что нужно от инфраструктуры.

### Этап A — Интерактивные drag tools (закрывает основной «interactive»-пробел)

| Файл                                   | Контент                                                                            | Event-log                |
|----------------------------------------|------------------------------------------------------------------------------------|--------------------------|
| `tests/test_tool_move_drag.d`          | select v6 куба → drag X-arrow на ~80px → проверить, что v6 переехал по оси X       | новый `move_arrow_x.log` |
| `tests/test_tool_rotate_drag.d`        | select face top → drag rotate-ring → 4 верхние вершины повернулись на ожидаемый угол | новый `rotate_ring.log` |
| `tests/test_tool_scale_drag.d`         | select all → drag scale-cone                                                       | новый `scale_uniform.log` |
| `tests/test_tool_move_plane_drag.d`    | drag по screen-plane (без axis)                                                    | новый `move_plane.log`   |
| `tests/test_handler_constraints.d`     | shift-зажат → axis-snap; drag вне gizmo → fallback plane-drag                      | новые логи               |

Инфраструктура: нужны event-log'и с большой амплитудой drag (>50px),
чтобы layout-сдвиги в 1–5px не ломали тест. Записывать в
стандартизированном viewport 1426×966.

### Этап B — Interactive drag + Toolpipe (то, ради чего toolpipe был сделан)

| Файл                                    | Контент                                                                                |
|-----------------------------------------|----------------------------------------------------------------------------------------|
| `tests/test_snap_during_drag.d`         | drag vertex с включённым snap-to-vertex → конечная позиция ≡ позиции snap-цели         |
| `tests/test_symm_during_drag.d`         | drag одной вершины с symmetry X → парная вершина переехала зеркально                   |
| `tests/test_falloff_radial_drag.d`      | two-stage radial: RMB-click создаёт диск, drag высоту; проверить плавное падение веса  |
| `tests/test_falloff_lasso_paint.d`      | painting falloff lasso → вершины внутри имеют weight=1, снаружи=0                      |
| `tests/test_acen_widget_clicks.d`       | клик по виджету action-center в viewport → меняется режим ACEN (Auto / Select / ...)   |

### Этап C — Не покрытые команды и edge-cases

| Файл                                | Контент                                                                                |
|-------------------------------------|----------------------------------------------------------------------------------------|
| `tests/test_commands_workplane.d`   | все 5: reset / offset / rotate / edit / alignToSelection — через `/api/command`        |
| `tests/test_commands_file_misc.d`   | `file.new`, `file.quit` (с подавлением реального exit), `history.show`                 |
| `tests/test_commands_snap_toggle.d` | `snap.toggle` + `snap.toggleType` (цикл по типам)                                      |
| `tests/test_lwo_edge_cases.d`       | загрузка LWO с PTCH / subpatch, повреждённый файл, пустой меш, 1k+ вершин              |
| `tests/test_gpu_select_direct.d`    | прямой dump ID-буфера через новый endpoint `/api/gpu-pick-buffer`; subpatch preview → cage |
| `tests/test_http_server_errors.d`   | malformed JSON, неизвестные методы / пути, конкурентные запросы → корректные коды ответа |

### Этап D — Performance regression suite

Создать отдельный test-runner (или флаг `--perf`):

| Файл                                | Замеряет                                                | Бюджет        |
|-------------------------------------|---------------------------------------------------------|---------------|
| `tests/perf/test_subpatch_drag.d`   | время `refreshPositions` при drag вершины subpatch куба 1024-face | < 8 ms / frame |
| `tests/perf/test_visibility_cache.d`| rebuild на меше 10k verts                               | < 50 ms        |
| `tests/perf/test_gpu_select_pick.d` | один pick на 50k face-меше                              | < 16 ms        |
| `tests/perf/test_picking_lasso.d`   | lasso через 8k verts                                    | < 30 ms        |

Чтобы не было flake — каждый тест запускать N раз, брать median,
бюджет с запасом ×1.5. Хранить baseline в `tests/perf/baseline.json`.

### Этап E — Дополнительные интерактивные сценарии (опционально)

- `tests/test_pen_complex_polygon.d` — рисование полигона из 5+ точек, замыкание, отмена
- `tests/test_subpatch_tab_toggle.d` — Tab в viewport, проверить переключение preview
- `tests/test_property_panel_drag.d` — drag float-slider в панели, проверить refire активной команды

---

## Инфраструктурные предпосылки

Большинство тестов A / B / C можно покрыть **существующими** эндпоинтами.
Минимум нужно добавить:

1. **`/api/gpu-pick-buffer`** (GET) — dump текущего ID-буфера для прямых
   тестов picker. Нужен только для C / `test_gpu_select_direct`.
2. **Стандартизированный viewport** для drag-тестов —
   `./vibe3d --test --viewport 1426×966` уже есть из MODO-parity-работы;
   зафиксировать его как обязательный для всех event-log тестов уровня A / B.
3. **Performance harness** — отдельный режим у `run_test.d` с
   медианами и бюджетами; результаты в `tests/perf/baseline.json`.

---

## Приоритеты

- **Высокий** (закрывают «interactive gap»): A1–A5, B1–B2
- **Средний**: B3–B5, C1 (workplane), D1–D2
- **Низкий**: C2–C6, D3–D4, E

---

## Риски и решения

- **Хрупкость event-log тестов к layout.** Минимизируется тем, что
  drag-расстояния делаются большими (> 50px) и viewport фиксируется
  на 1426×966.
- **Производительные тесты дают flake.** Брать median из N запусков,
  бюджет с запасом ×1.5, baseline хранить отдельно — обновляется
  только осознанно.
- **`file.quit` в тестах.** Подменять реальный `exit()` на флаг
  в `--test` режиме, чтобы тест мог проверить намерение, а процесс
  продолжил жить.
- **GPU-pick-buffer endpoint мутирует state?** Только read-only dump
  существующего буфера, без render-пасса под HTTP.
- **Состояние между unittest-ами.** Каждый тест начинать с
  `POST /api/reset` (правило уже зафиксировано предыдущей итерацией).
