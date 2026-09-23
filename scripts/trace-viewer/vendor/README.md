# Vendored modules

ES module builds, downloaded once from cdn.jsdelivr.net on 2026-09-23. No npm,
no build step, nothing fetched at runtime: `index.html` maps the bare import
names to these files with an import map. The `sourceMappingURL` comments were
removed, since the maps are not here.

| File | Package | Source |
| --- | --- | --- |
| `preact.module.js` | preact 10.29.8 | https://cdn.jsdelivr.net/npm/preact@10.29.8/dist/preact.module.js |
| `hooks.module.js` | preact/hooks 10.29.8 | https://cdn.jsdelivr.net/npm/preact@10.29.8/hooks/dist/hooks.module.js |
| `htm.module.js` | htm 3.1.1 | https://cdn.jsdelivr.net/npm/htm@3.1.1/dist/htm.module.js |
| `signals-core.module.js` | @preact/signals-core 1.14.4 | https://cdn.jsdelivr.net/npm/@preact/signals-core@1.14.4/dist/signals-core.module.js |
| `signals.module.js` | @preact/signals 2.11.2 | https://cdn.jsdelivr.net/npm/@preact/signals@2.11.2/dist/signals.module.js |

All MIT licensed. To update one, download the new version the same way, strip
the `//# sourceMappingURL=` comment, and change the version here.
