#ifndef CMARK_CONFIG_H
#define CMARK_CONFIG_H

#ifdef __cplusplus
extern "C" {
#endif

#define HAVE_STDBOOL_H 1
#ifdef HAVE_STDBOOL_H
  #include <stdbool.h>
#endif

#define HAVE___BUILTIN_EXPECT 1
#define HAVE___ATTRIBUTE__ 1

#ifdef HAVE___ATTRIBUTE__
  #define CMARK_ATTRIBUTE(list) __attribute__ (list)
#else
  #define CMARK_ATTRIBUTE(list)
#endif

#ifndef CMARK_INLINE
  #define CMARK_INLINE inline
#endif

#ifdef __cplusplus
}
#endif

#endif
