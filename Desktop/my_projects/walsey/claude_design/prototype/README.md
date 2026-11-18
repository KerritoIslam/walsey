# Prototype notes
- Navigation = `<a href="X.dc.html">` links between screens (map in docs/screens.md).
- Stage flows (pairing, Phone-PC connect, file transfer, automation save, assistant, settings) use `<sc-if value="{{sN}}">` blocks and `{{stN}}` click handlers; logic in prototype-logic.js.
- Assistant stages: 0 idle, 1 listening, 2 processing, 3 transcript, 4 success, 5 error. Recognized text is not execution.
- LED screens: `{{pick}}` picker, `{{setHex}}`, `{{setRgb}}`, `{{setB}}`, `{{save}}`.
- Concepts not implemented are labeled "Concept"/"Not supported" on screen; keep that in the real app (Desk LED strip: color + brightness only; no segments or receiver sound modes).
