# Null Safety — Nullable Types

## Objective
Practice making fields nullable with `?` and using `??` to safely provide fallback values when printing.

## Instructions
- Make `email` and `phone` nullable so they can be omitted.
- Fix `describe()` to show `'(no email)'` and `'(no phone)'` when those fields are null.

## Restrictions
- Do not rename variables, functions, or classes.
- Do not delete existing code.
- Do not use the null assertion operator (`!`).

## Starter Code

```dart
class User {
  final String name;
  final String email;      // TODO 1: emails are optional
  final String phone;      // TODO 2: phones are optional too

  User({required this.name, required this.email, required this.phone});
}

String describe(User u) {
  // TODO 3: Handle nulls — show fallback text for missing email/phone
  return '${u.name}: email=${u.email}, phone=${u.phone}';
}

void main() {
  User a = User(name: 'Alice', email: 'a@x.com', phone: '123-456');
  User b = User(name: 'Bob');                    // missing email AND phone
  User c = User(name: 'Carol', phone: '789-012'); // missing email only

  print(describe(a));
  print(describe(b));
  print(describe(c));
}
```

## Expected Output

```
Alice: email=a@x.com, phone=123-456
Bob: email=(no email), phone=(no phone)
Carol: email=(no email), phone=789-012
```
