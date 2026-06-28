# Final Challenge: Student Manager

## Objective
Combine null safety, collections, functions, closures, async, and exception handling into one complete program.

## Scenario
You are building a student management system. Each student is a `Map` with a name, grade, and optional email. The system loads data asynchronously, computes averages, filters top students, and must never crash — even when data is missing or the list is empty.

## Instructions
Fix all TODO items. The final program must compile, handle null values safely, and produce the expected output.

## Restrictions
- Do not rename variables or functions.
- Do not delete existing code.
- Do not use the null assertion operator (`!`).
- Use `async`/`await` (not `.then()`).
- Use `??` for string fallbacks.

## Starter Code

```dart
// Simulates async data loading — might return null
Future<List<Map<String, dynamic>>?> loadStudents() async {
  await Future.delayed(Duration(seconds: 1));
  return [
    {'name': 'Alice', 'grade': 92.0, 'email': 'alice@school.com'},
    {'name': 'Bob', 'grade': 78.0},
    {'name': 'Charlie', 'grade': 88.0, 'email': 'charlie@school.com'},
    {'name': 'Diana', 'grade': 65.0},
  ];
}

// TODO 1: Fix return type — might return null AND might receive null
List<Map<String, dynamic>> filterTop(List<Map<String, dynamic>> students) {
  // TODO 2: Handle null students safely — return null instead of crashing
  return students.where((s) {
    double grade = s['grade'] as double;
    return grade >= 80.0;
  }).toList();
}

// TODO 3: Fix return type — empty list or null should return null, not 0.0
double computeAverage(List<Map<String, dynamic>> students) {
  if (students.isEmpty) return 0.0;
  double sum = 0;
  for (var s in students) {
    sum += s['grade'] as double;
  }
  return sum / students.length;
}

String describeStudent(Map<String, dynamic> s) {
  String name = s['name'] as String;
  double grade = s['grade'] as double;
  // TODO 4: Get email safely — show 'N/A' if missing. Cast to String? first.
  String email = s['email'] as String;
  return '$name (Grade: $grade, Email: $email)';
}

Future<void> main() async {
  try {
    print('Loading...');
    List<Map<String, dynamic>>? data = await loadStudents();

    // TODO 5: Handle null data — print 'No data loaded' and exit early
    print('\n--- All Students ---');
    for (var s in data) { // might crash if data is null
      print(describeStudent(s));
    }

    // TODO 6: Safely get top students
    var top = filterTop(data);
    print('\n--- Top Students (grade >= 80) ---');
    for (var s in top ?? []) {
      print('  - ${s['name']}');
    }

    // TODO 7: Compute and print average — handle null return
    double avg = computeAverage(data);
    print('\nClass average: ${avg.toStringAsFixed(1)}');
  } catch (e) {
    print('Error: $e');
  } finally {
    print('Done.');
  }
}
```

## Expected Output

```
Loading...

--- All Students ---
Alice (Grade: 92.0, Email: alice@school.com)
Bob (Grade: 78.0, Email: N/A)
Charlie (Grade: 88.0, Email: charlie@school.com)
Diana (Grade: 65.0, Email: N/A)

--- Top Students (grade >= 80) ---
  - Alice
  - Charlie

Class average: 80.8
Done.
```
