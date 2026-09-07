# File Entries preserve the raw state of their source

ADR 0002 required every File Entry to carry an unmodified porcelain XY Code, but committed branch changes have no truthful XY Code. File Entries are therefore a tagged contract: Pending File Entries retain raw porcelain `xy`, while Committed File Entries retain raw `git diff --name-status` state. Core merges both sources by path with pending state taking precedence, allowing Renderers to distinguish them without presenting committed work as staged work.
