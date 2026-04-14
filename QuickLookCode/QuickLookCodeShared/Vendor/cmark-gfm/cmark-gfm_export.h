#ifndef CMARK_GFM_EXPORT_H
#define CMARK_GFM_EXPORT_H

// When building as a static library compiled into the framework,
// no dynamic export decoration is needed.
#define CMARK_GFM_EXPORT
#define CMARK_GFM_NO_EXPORT
#define CMARK_GFM_DEPRECATED __attribute__((__deprecated__))
#define CMARK_GFM_DEPRECATED_EXPORT CMARK_GFM_EXPORT CMARK_GFM_DEPRECATED
#define CMARK_GFM_DEPRECATED_NO_EXPORT CMARK_GFM_NO_EXPORT CMARK_GFM_DEPRECATED

#endif
