# Functions — Named & Optional Parameters

## Objective
Practice converting positional parameters to named (`{}`) and optional positional (`[]`) with defaults, and updating call sites accordingly.

## Instructions
Change the function signatures as described, then update the calls in `main()` to match the new signatures.

## Restrictions
- Do not rename functions.
- Do not delete existing code.
- Use `{}` for named parameters and `[]` for optional positional.

## Starter Code

```dart
// TODO 1: Convert to NAMED parameters.
// name is required, age is required, country defaults to 'Unknown'
void printPerson(String name, int age, String country) {
  print('$name ($age) from $country');
}

// TODO 2: Convert title to OPTIONAL POSITIONAL with default 'Guest'
void printBadge(String name, String title) {
  print('$name — $title');
}

void main() {
  // TODO 3: Update these calls to match the new signatures
  printPerson('Alice', 30, 'Canada');
  printPerson('Bob', 25, 'Unknown');
  printBadge('Alice', 'Admin');
  printBadge('Bob');
}
```

## Expected Output

```
Alice (30) from Canada
Bob (25) from Unknown
Alice — Admin
Bob — Guest
```
