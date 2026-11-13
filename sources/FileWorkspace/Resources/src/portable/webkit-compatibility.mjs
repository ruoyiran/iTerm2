import "./runtime-polyfills.js";
export function applyLegacyStyles(dark) {
  if (CSS.supports("color", "color-mix(in srgb,red,blue)")) return;
  let link = document.getElementById("legacy-orca-styles");
  if (!link) {
    link = document.createElement("link");
    link.id = "legacy-orca-styles";
    link.rel = "stylesheet";
    document.head.append(link);
  }
  link.href = new URL(`./legacy-${dark ? "dark" : "light"}.css`, document.baseURI).href;
}
