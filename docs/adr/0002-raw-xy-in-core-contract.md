# File Entries carry the raw porcelain XY Code, not derived status fields

The originally approved contract gave File Entries derived fields
(`status = "M"`, `staged = false`). Grilling the Mixed State case (`MM` —
staged, then modified again) showed derivation belongs to Renderers: VSCode
renders that file twice, our snacks Panel renders one row with letter + `✱`
marker, and Sprite's native panel may choose differently. So Core stores
git's own two-character XY Code verbatim and nothing derived. Consequence:
every Renderer owns its own letter/color/marker mapping, and the contract
never changes when a Renderer's presentation does.
