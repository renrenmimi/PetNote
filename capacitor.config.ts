import type { CapacitorConfig } from "@capacitor/cli";
import { KeyboardResize } from "@capacitor/keyboard";

const config: CapacitorConfig = {
  // Local development placeholder, deliberately not a registered App Store
  // identifier. Free Personal Team signing registers this under the personal
  // team only; choosing the real identifier is a separate decision.
  appId: "dev.local.petnote",
  appName: "PetNote",
  // The built web app ships inside the bundle. No server.url on purpose: a
  // device build must not be a shell that loads the production website.
  webDir: "dist",
  plugins: {
    Keyboard: {
      /*
       * Resize the native web view when the keyboard appears, rather than
       * letting iOS leave the layout viewport at full height and scroll the
       * visual viewport underneath it.
       *
       * This is here because CSS cannot express it. Measured on an iPhone 17
       * Pro simulator with a field focused: window.innerHeight went 874 → 498
       * but the layout viewport stayed 874, so the document scrolled 376px and
       * carried the reserved safe-area strip up under the clock — with
       * `position: fixed` and `100dvh` both pinned to the *unshrunk* layout
       * viewport, and no transformed ancestor to blame. With Native resize the
       * web view frame itself shrinks, so the viewport the page sees is the
       * space actually left above the keyboard.
       *
       * CommentSection's visualViewport compensation degrades to a no-op
       * under this mode (innerHeight - height - offsetTop becomes 0) rather
       * than double-counting.
       */
      resize: KeyboardResize.Native,
    },
  },
};

export default config;
