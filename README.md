# vibe3d

Простой 3D-редактор меша, вдохновлённый MODO и LightWave. Написан на D с использованием OpenGL 3.3 и SDL2.

## Возможности

- Полигональное редактирование меша в трёх режимах: **Vertices**, **Edges**, **Polygons**
- Инструменты трансформации: **Move** (W), **Rotate** (E), **Scale** (R)
- Подсветка при наведении и выделение с поддержкой Shift (добавить) и Ctrl (убрать)
- Connected selection — заливка связных компонентов (`]`)
- Subdivision Surface — алгоритм Catmull-Clark (Shift+D)
- Fit to selection — центрирование камеры на выделении (Shift+A)
- Адаптивный размер гизмо — постоянный угловой размер независимо от FOV и масштаба
- Геометрическое определение видимости: невидимые грани, рёбра и вершины не выделяются
- Отрисовка через OpenGL VBO/VAO с оптимизациями (`glMapBuffer`, GPU offset drag)
- ImGui-панель с информацией о меше и камере
- Логирование и воспроизведение событий (`--playback <file>`)

## Управление

| Действие | Клавиши / мышь |
|---|---|
| Орбита камеры | Alt + ЛКМ |
| Панорама | Alt + Shift + ЛКМ |
| Зум | Ctrl + Alt + ЛКМ |
| Выделить | ЛКМ / перетащить |
| Добавить к выделению | Shift + ЛКМ |
| Убрать из выделения | Ctrl + ЛКМ |
| Connected selection | `]` |
| Fit to selection | Shift + A |
| Режим Vertices | `1` |
| Режим Edges | `2` |
| Режим Polygons | `3` |
| Move tool | `W` |
| Rotate tool | `E` |
| Scale tool | `R` |
| Subdivision (Catmull-Clark) | Shift + D |

## Сборка

Требуется [DUB](https://dub.pm/) и компилятор D (DMD или LDC), а также установленные SDL2.

```sh
dub build
```

Запуск:

```sh
./vibe3d
```

Воспроизведение записанной сессии:

```sh
./vibe3d --playback events.log
```

## Зависимости

- [bindbc-sdl](https://github.com/BindBC/bindbc-sdl) — SDL2 биндинги
- [bindbc-opengl](https://github.com/BindBC/bindbc-opengl) — OpenGL биндинги
- [d_imgui](https://github.com/shulc/imgui) — Dear ImGui для D

## Лицензия

MIT
