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
      /*
       * Tint the strip the web view vacates, instead of leaving the native
       * view showing through it.
       *
       * Native resize shrinks the web view frame the instant the keyboard is
       * announced, while the keyboard itself slides up over about 250 ms.
       * For that quarter second there is a bare native rectangle where the
       * keyboard is about to be, and with the default 'off' it is black —
       * which is what someone typing on the device sees and what a settled
       * screenshot never catches.
       *
       * 'dom' rather than 'auto': 'auto' prefers a fixed colour from this
       * file, and a fixed colour cannot be right in both light and dark.
       * 'dom' re-reads the body background every time the keyboard is about
       * to show, so it follows the theme, and `--app-backdrop` in index.css
       * lets a surface with its own background say what that colour is.
       */
      autoBackdropColor: "dom",
    },
  },
};

export default config;
