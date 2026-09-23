// The browser libraries that app/index.html loads before app/preview.js, as
// globals. Only what preview.js uses is declared, and loosely: the type check
// is about the page's own code, not about these libraries.

declare function markdownit(options?: Record<string, unknown>): any;
/** markdown-it plugins, passed to md.use(). */
declare const texmath: unknown;
declare const markdownitFootnote: unknown;
declare const markdownitEmoji: unknown;

declare const hljs: {
  getLanguage(name: string): object | undefined;
  highlight(code: string, options: { language: string; ignoreIllegals?: boolean }): { value: string };
};

declare const katex: {
  renderToString(tex: string, options?: { displayMode?: boolean; throwOnError?: boolean }): string;
};

declare const DOMPurify: {
  sanitize(html: string, config?: Record<string, unknown>): string;
};

/** Loaded on demand, when a document has a diagram. */
interface Mermaid {
  initialize(config: Record<string, unknown>): void;
  render(id: string, text: string): Promise<{ svg: string }>;
}

interface Window {
  markdownit: typeof markdownit;
  mermaid?: Mermaid;
}
