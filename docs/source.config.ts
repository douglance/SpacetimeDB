import { defineConfig, defineDocs } from 'fumadocs-mdx/config';
import remarkDirective from 'remark-directive';
import { remarkDirectiveAdmonition } from 'fumadocs-core/mdx-plugins';
import { pageSchema } from 'fumadocs-core/source/schema';
import { remarkStripDocusaurusImports } from './src/lib/remark-strip-docusaurus-imports';

export const docs = defineDocs({
  dir: 'docs',
  docs: {
    schema: pageSchema,
  },
});

export default defineConfig({
  mdxOptions: {
    // Disable remark-structure to avoid serialization errors from Docusaurus
    // JSX elements (<Tabs>, <TabItem>) in .md files. Search/structured data
    // can be re-enabled once content is fully migrated to .mdx.
    remarkStructureOptions: false,
    remarkPlugins: [
      remarkStripDocusaurusImports,
      remarkDirective,
      [remarkDirectiveAdmonition, {
        types: {
          note: 'info',
          tip: 'info',
          info: 'info',
          warn: 'warning',
          warning: 'warning',
          danger: 'error',
          caution: 'warning',
          success: 'success',
        },
      }],
    ],
    rehypeCodeOptions: {
      themes: {
        light: 'dracula',
        dark: 'dracula',
      },
      langs: [
        'sql', 'rust', 'csharp', 'typescript', 'bash', 'json', 'toml',
        'python', 'c', 'cpp', 'proto', 'fsharp', 'systemd', 'tsx',
        'css', 'nginx', 'markdown', 'xml', 'yaml', 'powershell', 'shellscript',
      ],
      defaultLanguage: 'text',
    },
  },
});
