<p align="center"><img src="static/punpun-mark.svg" width="88" alt="PunPun"></p>

# PunPun Documentation

<p align="center"><strong>Fast, searchable and readable without a JavaScript build toolchain.</strong></p>

This repository holds the source **and** the published build of the PunPun
documentation site. The language itself lives in
[`pumpumlang/punpun`](https://github.com/pumpumlang/punpun); the package
manager lives in [`pumpumlang/punpun-ppx`](https://github.com/pumpumlang/punpun-ppx).

| Property | Design |
| --- | --- |
| Hosting | Plain static files at the repository root; GitHub Pages compatible |
| Build dependency | Python standard library only |
| Search | Generated local `search.json` |
| Version | Read from this repository's `VERSION` file |
| Runtime service | None |

## Layout

| Path | Contents |
| --- | --- |
| `content/` | Markdown source for every site page |
| `static/` | `site.css`, `site.js` and the brand mark |
| `reference/` | Long-form reference material not rendered into the site |
| `build.py` | The site generator |
| `*.html`, `assets/`, `search.json` | Generated output, committed for GitHub Pages |

Everything outside that last row is hand-maintained. `build.py` only ever
rewrites the generated paths, so it is safe to run in a dirty checkout.

## Build and preview

```sh
python3 build.py
python3 -m http.server 8000
```

Open <http://localhost:8000> and stop the server with `Ctrl+C`.

## Edit documentation

1. Change or add Markdown in `content/`.
2. Run `python3 build.py`.
3. Commit both the Markdown change and the regenerated HTML.

`python3 build.py --check` fails when the committed HTML no longer matches
`content/`, which is what CI runs on every push and pull request.

## Adding a page

Create `content/<slug>.md` starting with a single `# Title` heading. To place
it in the sidebar, add `<slug>` to the appropriate group in `NAV_GROUPS` in
`build.py`; pages left out of every group are collected under **Reference**
automatically.

## Scope

These pages document behavior that PunPun actually implements. Unfinished
areas are labeled as planned rather than presented as shipped. The frozen 0.6
design specification lives in the language repository under `spec/`, and public
pages must keep frozen design distinct from executable compiler behavior.

## Releasing

The documentation version tracks the language release it describes. Update
`VERSION`, rebuild, and commit; GitHub Pages serves the repository root.
