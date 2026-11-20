if (Date.now() >= deadline) return {error_code:'timeout'};
if (location.origin !== expectedOrigin) return {error_code:'navigation_changed'};
try {
    const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
    const value = await new AsyncFunction(expression)();
    // Round-trip here rather than letting WebKit silently drop unsupported values.
    const json = JSON.stringify(value === undefined ? null : value);
    if (Date.now() >= deadline) return {error_code:'timeout'};
    if (location.origin !== expectedOrigin) return {error_code:'navigation_changed'};
    return {value:JSON.parse(json)};
} catch (_) {
    return {error_code:'javascript_error'};
}
