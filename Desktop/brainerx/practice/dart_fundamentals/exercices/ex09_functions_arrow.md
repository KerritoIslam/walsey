# Functions — Arrow Syntax & Return Types

## Objective
Practice fixing incorrect return types and converting single-expression functions to arrow syntax (`=>`).

## Instructions
Fix return types where they are wrong and convert eligible functions to arrow syntax.

## Restrictions
- Do not rename functions or parameters.
- Do not delete existing code.
- Use `=>` for single-expression functions.

## Starter Code

```dart
// TODO 1: Fix return type — returns the larger of two numbers
int max(int a, int b) {
  if (a > b) return a;
  return b;
}

// TODO 2: Convert to arrow syntax — single expression
String repeat(String s, int n) {
  return s * n;
}

// TODO 3: Fix return type — this checks even/odd (true/false)
String isEven(int n) {
  return n % 2 == 0;
}

// TODO 4: Return type does NOT match the returned value — fix it
int describeLength(String s) {
  return 'The string "${s}" has ${s.length} characters';
}

void main() {
  print(max(10, 5));
  print(repeat('Hi', 3));
  print(isEven(7));
  print(describeLength('Dart'));
}
```

## Expected Output

```
10
HiHiHi
false
The string "Dart" has 4 characters
```
