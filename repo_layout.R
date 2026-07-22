# =============================================================================
# repo_layout.R — dump an LLM-friendly map of the repository.
#
# WHAT IT DOES: walks the repo from ROOT, and writes repo_layout.txt containing
#   (1) a directory tree with size + line count per file,
#   (2) a flat list of relative paths (git tracked/untracked marked),
#   (3) likely-cruft + possible-secret flags to help pruning,
#   (4) a summary.
# It reads NO file contents except line counts of text files (never prints them),
# so it's safe to share. It never prints the contents of .env or secrets.
#
# HOW TO USE (RStudio): set ROOT to your repo root, then Source this file.
#   Or from a shell:  Rscript repo_layout.R
# Then upload the generated repo_layout.txt.
#
# (Shell alternative if you prefer: `git ls-files` from the repo root also gives
#  an LLM-friendly tracked-file list.)
# =============================================================================

# ─── CONFIG ──────────────────────────────────────────────────────────────────
ROOT <- "."                         # repo root (default: current dir / getwd())
OUT  <- "repo_layout.txt"
MAX_LINES_BYTES <- 1.5e6            # don't line-count files larger than this

# Directory names excluded anywhere in the path (noise / generated / heavy):
EXCLUDE_DIRS <- c(".git", ".Rproj.user", ".Rhistory", "node_modules", "__pycache__",
                  ".venv", "venv", "site_libs", ".quarto", ".cache", ".idea",
                  ".pytest_cache", ".mypy_cache", "renv")
# Directory-name suffixes excluded (knitr/pkgdown/rmarkdown artifacts):
EXCLUDE_DIR_SUFFIX <- c("_cache", "_files")
# Individual filenames excluded:
EXCLUDE_FILES <- c(".DS_Store", "Thumbs.db")

# Cruft flags (included in the tree, but listed as prune candidates):
CRUFT_EXT   <- c("rdata","rds","tar","gz","tgz","zip","log","pyc","o","so")
CRUFT_PATH  <- c("docs/", "/docs/", "man/figures/")   # rendered / generated output
# Possible secrets (flagged with a warning; never opened):
SECRET_HINTS <- c("^\\.env$", "\\.env$", "\\.env\\.", "secret", "\\.pem$",
                  "\\.key$", "id_rsa", "\\.p12$", "\\.pfx$")
# Domain-specific: files we believe are superseded in this project.
SUPERSEDED <- c("worker_batch.R")   # replaced by worker_curveR.R

# ═══════════════════════════════════════════════════════════════════════════
root <- normalizePath(ROOT, mustWork = TRUE)
setwd(root)

# git context (best-effort)
git_yes <- tryCatch(system2("git", c("rev-parse","--is-inside-work-tree"),
                            stdout = TRUE, stderr = FALSE), error = function(e) NA)
in_git  <- isTRUE(length(git_yes) && git_yes[1] == "true")
git_branch <- if (in_git) tryCatch(system2("git", c("rev-parse","--abbrev-ref","HEAD"),
                            stdout = TRUE, stderr = FALSE)[1], error=function(e) "?") else NA
tracked <- if (in_git) tryCatch(system2("git", c("ls-files"), stdout = TRUE, stderr = FALSE),
                                error = function(e) character(0)) else character(0)
tracked <- gsub("\\\\", "/", tracked)

# gather all files
all_files <- list.files(".", recursive = TRUE, all.files = TRUE, no.. = TRUE,
                        include.dirs = FALSE, full.names = FALSE)
all_files <- gsub("\\\\", "/", all_files)

excluded_dir <- function(rel) {
  parts <- strsplit(rel, "/")[[1]]
  d <- parts[-length(parts)]
  if (length(d) && any(d %in% EXCLUDE_DIRS)) return(TRUE)
  if (length(d) && any(vapply(d, function(x)
        any(endsWith(x, EXCLUDE_DIR_SUFFIX)), logical(1)))) return(TRUE)
  FALSE
}
keep <- vapply(all_files, function(f)
  !(basename(f) %in% EXCLUDE_FILES) && !excluded_dir(f), logical(1))
files <- sort(all_files[keep])

# helpers
fmt_size <- function(b) {
  if (is.na(b)) return("      ?")
  u <- c("B","KB","MB","GB"); i <- 1
  while (b >= 1024 && i < length(u)) { b <- b/1024; i <- i + 1 }
  sprintf("%6.1f %s", b, u[i])
}
count_lines <- function(path, size) {
  if (is.na(size) || size > MAX_LINES_BYTES) return(NA_integer_)
  ext <- tolower(tools::file_ext(path))
  bin <- c("png","jpg","jpeg","gif","bmp","ico","pdf","zip","gz","tgz","tar",
           "rds","rdata","woff","woff2","ttf","eot","exe","so","o","dll","class")
  if (ext %in% bin) return(NA_integer_)
  tryCatch(length(readLines(path, warn = FALSE)), error = function(e) NA_integer_)
}

sizes <- file.info(files)$size
lines <- mapply(count_lines, files, sizes)

# ─── build tree ──────────────────────────────────────────────────────────────
prefixes <- unique(unlist(lapply(files, function(p) {
  parts <- strsplit(p, "/")[[1]]
  if (length(parts) > 1)
    vapply(seq_len(length(parts) - 1), function(k) paste(parts[1:k], collapse = "/"), "")
  else character(0)
})))
nodes <- sort(unique(c(prefixes, files)))
is_dir <- nodes %in% prefixes & !(nodes %in% files)

tree_lines <- c(paste0(basename(root), "/"))
for (i in seq_along(nodes)) {
  n <- nodes[i]; depth <- length(strsplit(n, "/")[[1]])
  indent <- strrep("  ", depth)
  base <- basename(n)
  if (is_dir[i]) {
    tree_lines <- c(tree_lines, sprintf("%s%s/", indent, base))
  } else {
    j <- match(n, files)
    ln <- if (is.na(lines[j])) "  bin/large" else sprintf("%5d lines", lines[j])
    tree_lines <- c(tree_lines, sprintf("%s%-32s [%s, %s]", indent, base,
                                        fmt_size(sizes[j]), ln))
  }
}

# ─── flat list (with git status) ─────────────────────────────────────────────
flat <- vapply(files, function(f) {
  status <- if (!in_git) " " else if (f %in% tracked) "T" else "U"
  sprintf("[%s] %s", status, f)
}, "")

# untracked-but-present (candidate cruft or forgot-to-add)
untracked <- if (in_git) files[!(files %in% tracked)] else character(0)
# tracked-but-missing-on-disk (deleted but still in git)
ghost <- if (in_git) tracked[!(tracked %in% files)] else character(0)

# ─── prune candidates ────────────────────────────────────────────────────────
is_cruft <- vapply(files, function(f) {
  ext <- tolower(tools::file_ext(f))
  ext %in% CRUFT_EXT || any(vapply(CRUFT_PATH, function(p) grepl(p, f, fixed = TRUE), logical(1)))
}, logical(1))
cruft <- files[is_cruft]

is_secret <- vapply(files, function(f)
  any(vapply(SECRET_HINTS, function(rx) grepl(rx, basename(f), ignore.case = TRUE) ||
        grepl(rx, f, ignore.case = TRUE), logical(1))), logical(1))
# don't flag the safe template
secrets <- setdiff(files[is_secret], c(".env.example"))

superseded_found <- files[basename(files) %in% SUPERSEDED]

# ─── write output ────────────────────────────────────────────────────────────
sec <- function(title) c("", paste0("== ", title, " =="))
out <- c(
  "# REPOSITORY LAYOUT",
  sprintf("# root:      %s", root),
  sprintf("# git:       %s%s", if (in_git) "yes" else "no",
          if (in_git) sprintf("  (branch: %s, tracked files: %d)", git_branch, length(tracked)) else ""),
  sprintf("# generated: %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
  sprintf("# excluded:  %s (+ *%s dirs)", paste(EXCLUDE_DIRS, collapse=", "),
          paste(EXCLUDE_DIR_SUFFIX, collapse=", *")),
  sec("TREE"), tree_lines,
  sec("FLAT LIST  ([T]=git-tracked, [U]=untracked, [ ]=no git)"), flat,
  sec("PRUNE CANDIDATES — likely generated/cruft (review before deleting)"),
    if (length(cruft)) cruft else "(none)",
  sec("SUPERSEDED — believed replaced in this project"),
    if (length(superseded_found)) superseded_found else "(none)",
  sec("POSSIBLE SECRETS — must NOT be committed; verify .gitignore"),
    if (length(secrets)) secrets else "(none)",
  sec("UNTRACKED (present on disk, not in git)"),
    if (length(untracked)) untracked else "(none)",
  sec("GHOSTS (in git, missing on disk)"),
    if (length(ghost)) ghost else "(none)",
  sec("SUMMARY"),
  sprintf("files shown: %d   dirs: %d   total size: %s",
          length(files), sum(is_dir), fmt_size(sum(sizes, na.rm = TRUE)))
)

writeLines(out, OUT)
cat(paste(out, collapse = "\n"), "\n")
cat(sprintf("\n---\nWrote %s (%d lines). Upload that file.\n", normalizePath(OUT), length(out)))
