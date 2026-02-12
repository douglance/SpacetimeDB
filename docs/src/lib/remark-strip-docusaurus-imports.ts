/**
 * Remark plugin that strips Docusaurus-specific import statements from MDX
 * and remaps unsupported code block languages to plain text.
 * This allows the existing Docusaurus content files to be processed by Fumadocs
 * without modification. The components (Tabs, TabItem) are provided globally
 * via mdx-components.tsx instead.
 */

// Languages not bundled with Shiki that appear in existing content
const UNSUPPORTED_LANGS = new Set(['ebnf', 'psql']);

interface TreeNode {
  type: string;
  value?: string;
  lang?: string;
  children?: TreeNode[];
}

export function remarkStripDocusaurusImports() {
  return (tree: { children: TreeNode[] }) => {
    tree.children = tree.children.filter((node) => {
      if (node.type === 'mdxjsEsm' || node.type === 'mdxFlowExpression') {
        const value = node.value ?? '';
        // Strip imports from @theme/* (Docusaurus components)
        if (value.includes('@theme/')) {
          return false;
        }
      }
      return true;
    });

    // Remap unsupported code block languages to plain text
    visit(tree as TreeNode);
  };
}

function visit(node: TreeNode) {
  if (node.type === 'code' && node.lang && UNSUPPORTED_LANGS.has(node.lang)) {
    node.lang = 'text';
  }
  if (node.children) {
    for (const child of node.children) {
      visit(child);
    }
  }
}
