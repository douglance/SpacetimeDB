import { docs } from 'fumadocs-mdx:collections/server';
import { loader } from 'fumadocs-core/source';
import type { InferPageType } from 'fumadocs-core/source';
import { createElement } from 'react';

function SparkleIcon() {
  return createElement('svg', {
    width: 16,
    height: 16,
    viewBox: '0 0 24 24',
    fill: 'currentColor',
    style: { color: 'rgba(182, 192, 207, 0.7)' },
  }, createElement('path', {
    d: 'M12 3l1.912 5.813a2 2 0 0 0 1.275 1.275L21 12l-5.813 1.912a2 2 0 0 0-1.275 1.275L12 21l-1.912-5.813a2 2 0 0 0-1.275-1.275L3 12l5.813-1.912a2 2 0 0 0 1.275-1.275L12 3z',
  }));
}

/**
 * Strip numeric prefixes (e.g. "00100-") from a path segment.
 */
function stripNumericPrefix(segment: string): string {
  return segment.replace(/^\d+-/, '');
}

/**
 * Custom slug generation that strips Docusaurus-style numeric prefixes
 * from file paths and handles special cases:
 * - "00100-getting-started/00100-getting-started" → ["getting-started"]
 *   (file with same name as parent dir becomes index)
 * - "00200-core-concepts/00000-index" → ["core-concepts"]
 *   (files named "index" or "00000-index" become the directory index)
 */
function docusaurusSlugs(file: { path: string }): string[] {
  // file.path is relative to the `dir`, e.g. "00200-core-concepts/00100-databases.md"
  const segments = file.path
    .replace(/\.(mdx?|md)$/, '')
    .split('/')
    .map(stripNumericPrefix);

  // If the last segment is "index", remove it (becomes directory index)
  if (segments.length > 1 && segments[segments.length - 1] === 'index') {
    segments.pop();
  }

  // If the last segment matches its parent (e.g. getting-started/getting-started),
  // it's a directory index page — remove the duplicate
  if (
    segments.length >= 2 &&
    segments[segments.length - 1] === segments[segments.length - 2]
  ) {
    segments.pop();
  }

  return segments;
}

export const source = loader({
  baseUrl: '/',
  source: docs.toFumadocsSource(),
  slugs: docusaurusSlugs,
  icon(icon) {
    if (icon === 'sparkle') {
      return createElement(SparkleIcon);
    }
    return undefined;
  },
});

export type Page = InferPageType<typeof source>;

export async function getLLMText(page: Page) {
  // TODO: Re-enable when includeProcessedMarkdown is compatible with JSX-in-MD files
  return `# ${page.data.title}

${page.data.description ?? ''}`;
}
