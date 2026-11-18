// Image: a picture loaded from `url` (https, http to IP addresses and local
// hosts, file:// or data:image), cached natively. `size` makes it a square;
// `contentMode` is fill (default, crops) or fit; `cornerRadius` rounds it and
// `circle` clips it to a circle. `placeholder` (an SF Symbol) shows while it
// loads and when it fails. Decorative unless it has a `label`.
// The page uses a data URL, a 16 × 8 picture, red on the left and blue on
// the right, so it draws the same with no network.
var picture = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAICAIAAAB/FOjAAAAAGElEQVR42mN46uGLFdkl38WKGEY10EIDAHRHvgHbOOZdAAAAAElFTkSuQmCC";

function Caption(text) {
  return h(Text, { size: 11, color: "secondary" }, text);
}

Playhouse.render(h(Stack, { axis: "v", spacing: 12, align: "leading", group: true, testID: "image-page" },
  Caption("fill (default), 64 × 64: covers the square and crops the sides"),
  h(Image, { url: picture, size: 64, label: "Filled picture", testID: "image-fill" }),
  Caption("fit, 64 × 64: shows all of it"),
  h(Image, { url: picture, size: 64, contentMode: "fit", label: "Fitted picture", testID: "image-fit" }),
  Caption("circle and cornerRadius 12, as profile pictures"),
  h(Stack, { axis: "h", spacing: 12 },
    h(Image, { url: picture, size: 48, circle: true, label: "Round picture", testID: "image-circle" }),
    h(Image, { url: picture, size: 48, cornerRadius: 12, label: "Rounded picture", testID: "image-rounded" }),
    h(Image, { url: picture, width: 64, height: 32, help: "Decorative: no label", testID: "image-decorative-catalog" })),
  Caption("A URL that fails shows its placeholder"),
  h(Image, { url: "https://playhouse.invalid/avatar.png", size: 48, circle: true, placeholder: "person.crop.circle",
    label: "Missing picture", testID: "image-failed" })
));
