#ifndef CTREESITTER_PARSERS_H
#define CTREESITTER_PARSERS_H

// The vendored tree-sitter language parsers. TSLanguage stays opaque here — the real
// definition lives in the tree-sitter runtime SwiftTreeSitter brings in, and Swift only
// ever passes these pointers through to it.
typedef struct TSLanguage TSLanguage;

#ifdef __cplusplus
extern "C" {
#endif

const TSLanguage *tree_sitter_swift(void);
const TSLanguage *tree_sitter_bash(void);
const TSLanguage *tree_sitter_c(void);
const TSLanguage *tree_sitter_cpp(void);
const TSLanguage *tree_sitter_c_sharp(void);
const TSLanguage *tree_sitter_go(void);
const TSLanguage *tree_sitter_javascript(void);
const TSLanguage *tree_sitter_json(void);
const TSLanguage *tree_sitter_python(void);
const TSLanguage *tree_sitter_ruby(void);
const TSLanguage *tree_sitter_rust(void);
const TSLanguage *tree_sitter_typescript(void);
const TSLanguage *tree_sitter_tsx(void);
const TSLanguage *tree_sitter_yaml(void);
const TSLanguage *tree_sitter_markdown(void);
const TSLanguage *tree_sitter_markdown_inline(void);

#ifdef __cplusplus
}
#endif

#endif
