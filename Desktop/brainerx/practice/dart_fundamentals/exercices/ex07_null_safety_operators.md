# Null Safety — Safe Access & Null-Aware Assignment

## Objective
Practice using `?.` for safe property access, `??` for fallback values, and `??=` for conditional assignment.

## Instructions
Fix the code so accessing properties on nullable values never crashes and the output matches.

## Restrictions
- Do not rename variables.
- Do not delete existing code.
- Do not use the null assertion operator (`!`).

## Starter Code

```dart
void main() {
  String? name;
  String? nickname;

  // TODO 1: Print name length safely — use ?. so it doesn't crash
  // If name is null, print 'null' as the length
  print('Name length: ${name.length}');

  // TODO 2: Assign 'Anonymous' ONLY if nickname is null
  // Currently always overwrites — fix with ??=
  nickname = 'Anonymous';
  print('Nickname: $nickname');

  // TODO 3: Print the first character of name safely
  // If name is null, show '?'
  // Hint: combine ?. with ??
  print('First char: ${name[0]}');
}
```

## Expected Output

```
Name length: null
Nickname: Anonymous
First char: ?
```
