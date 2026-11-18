# Components (class names come from styles/walsey.css)

| Component | Markup | Flutter mapping idea |
|---|---|---|
| Primary / secondary / danger button | `<button class="bt">`, `class="bs"`, `class="bd bs"` | FilledButton / tonal / error tonal, min height 44 |
| Status badge | `<span class="b on|wa|of|er|vi">` | Chip with fixed color roles |
| Card | `<div class="c">` + `<div class="h">` label | Container r10, border #262A38 |
| List row | `<a class="ln">` title, caption, trailing badge | ListTile with divider |
| Toggle | `<input type="checkbox" class="tg">` | Switch (40x22) |
| Progress | `<div class="pg"><i style="width:60%"></i></div>` | LinearProgressIndicator h6 |
| Input | `<input class="in">` | TextField r8 |
| Filter chip | `<span class="chip">` | ChoiceChip |
| Windows nav item | `<a class="nv [na]">` in 210px sidebar | NavigationRail/custom sidebar |
| Android bottom nav | `<div class="bn"><a [class="na"]>` | NavigationBar, 6 destinations |
| Filled color picker | circle button, radial white center over conic hue gradient; click maps angle to hue, distance to lightness | CustomPainter + GestureDetector |
| Bottom sheet | see screens/states/S-LEDUnsupported.html | showModalBottomSheet |
