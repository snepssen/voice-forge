/** Hand-editable directions which shape one inference call's phoneme stream. */
export type PerformanceBeat = "short" | "medium" | "long";

export type PerformanceToken =
  | { kind: "text"; text: string; focused: boolean }
  | { kind: "beat"; beat: PerformanceBeat };

export const beatPads: Record<PerformanceBeat, number> = {
  short: 3, medium: 6, long: 12,
};

const beatCues: [string, PerformanceBeat][] = [
  ["[[beat:short]]", "short"],
  ["[[beat:medium]]", "medium"],
  ["[[beat:long]]", "long"],
  ["[[beat]]", "medium"],
];

function appendText(tokens: PerformanceToken[], text: string, focused: boolean) {
  if (!text) return;
  const previous = tokens[tokens.length - 1];
  if (previous?.kind === "text" && previous.focused === focused) previous.text += text;
  else tokens.push({ kind: "text", text, focused });
}

/** An unmatched `*` remains literal rather than consuming the rest of a script. */
export function parsePerformanceMarkup(source: string): PerformanceToken[] {
  const tokens: PerformanceToken[] = [];
  let plain = "", i = 0;
  const flush = () => { appendText(tokens, plain, false); plain = ""; };

  while (i < source.length) {
    const cue = source[i] === "["
      ? beatCues.find(([text]) => source.slice(i, i + 15).toLowerCase().startsWith(text))
      : undefined;
    if (cue) {
      flush(); tokens.push({ kind: "beat", beat: cue[1] }); i += cue[0].length; continue;
    }
    if (source[i] === "*") {
      const close = source.indexOf("*", i + 1);
      if (close > i + 1 && !/\s/.test(source[i + 1]!) && !/\s/.test(source[close - 1]!)) {
        flush(); appendText(tokens, source.slice(i + 1, close), true); i = close + 1; continue;
      }
    }
    plain += source[i]!; i++;
  }
  flush();
  return tokens;
}

/** The words the listener will hear, without cue notation. */
export function spokenText(source: string): string {
  return parsePerformanceMarkup(source)
    .map(t => t.kind === "text" ? t.text : " ").join("")
    .trim().split(/\s+/).filter(Boolean).join(" ");
}

export const performanceWordCount = (source: string): number =>
  spokenText(source).split(/\s+/).filter(Boolean).length;

export function cueCounts(source: string): { focus: number; beats: number } {
  let focus = 0, beats = 0;
  for (const token of parsePerformanceMarkup(source)) {
    if (token.kind === "beat") beats++;
    else if (token.focused) focus++;
  }
  return { focus, beats };
}
