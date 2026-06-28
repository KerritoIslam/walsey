# final vs const

## Objective
Practice distinguishing between `final` (runtime constant) and `const` (compile-time constant), including understanding that arithmetic on literals can be `const`.

## Instructions
Replace the wrong modifier (`final` or `const` or `var`) with the correct one. Do not change the values.

## Restrictions
- Do not rename variables.
- Do not change the assigned values.
- Do not delete existing code.

## Starter Code

```dart
void main() {
  // TODO 1: This string literal is known at compile time
  final appVersion = 'v2.5.0';

  // TODO 2: DateTime.now() is only known at runtime
  const startedAt = DateTime.now();

  // TODO 3: 9.81 is a literal — known at compile time
  final gravity = 9.81;

  // TODO 4: 100 * 3 is a constant expression — it CAN be const
  final maxScore = 100 * 3;

  // TODO 5: This should be set once and never reassigned
  var theme = 'dark';
  theme = 'light'; // should cause a compile error

  print('$appVersion started at $startedAt');
  print('Gravity: $gravity, Max score: $maxScore');
  print('Theme: $theme');
}
```

## Expected Output

```
v2.5.0 started at ...
Gravity: 9.81, Max score: 300
Theme: dark
```
