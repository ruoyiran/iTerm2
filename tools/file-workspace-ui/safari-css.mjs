import { transform, transformStyleAttribute } from "lightningcss";
function variables(css, selector) {
  const result = {};
  for (const match of css.matchAll(new RegExp(selector + "(?:\\s*,[^{}]+)?\\s*\\{([^}]+)\\}", "g")))
    for (const item of match[1].matchAll(/(--[\w-]+)\s*:\s*([^;{}]+);?/g))
      result[item[1]] = item[2].trim();
  return result;
}
function expandVariables(value, variables) {
  for (let i = 0; i < 30 && value.includes("var("); i++) {
    const next = value.replace(
      /var\((--[\w-]+)(?:,([^()]+))?\)/g,
      (all, key, fallback) => variables[key] ?? fallback ?? all,
    );
    if (next === value) break;
    value = next;
  }
  return value;
}
function replaceMixes(css, variables) {
  let result = "",
    from = 0;
  for (let start = css.indexOf("color-mix("); start >= 0; start = css.indexOf("color-mix(", from)) {
    let depth = 1,
      end = start + 10;
    for (; end < css.length && depth; end++) {
      if (css[end] === "(") depth++;
      if (css[end] === ")") depth--;
    }
    const expression = expandVariables(css.slice(start, end), variables);
    let fallback = expression;
    if (!expression.includes("var(")) {
      try {
        const output = transformStyleAttribute({
          code: Buffer.from("color:" + expression),
          targets: { safari: 16 << 16 },
          minify: true,
        }).code.toString();
        fallback = output.replace(/^color:/, "").replace(/;$/, "");
      } catch {
        fallback = expression;
      }
    }
    result += css.slice(from, start) + fallback;
    from = end;
  }
  return result + css.slice(from);
}
export function safariStyles(compiled, original) {
  const light = { ...variables(compiled, ":root,:host"), ...variables(original, ":root") };
  const dark = { ...light, ...variables(original, "\\.dark") };
  const compile = (vars) =>
    transform({
      code: Buffer.from(replaceMixes(compiled, vars)),
      filename: "orca.css",
      targets: { safari: 16 << 16 },
      minify: true,
      errorRecovery: false,
    }).code;
  return { light: compile(light), dark: compile(dark) };
}
