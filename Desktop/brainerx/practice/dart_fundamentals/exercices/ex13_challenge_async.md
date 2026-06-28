# Challenge: Weather Report Fetcher

## Objective
Combine `async`/`await`, `Future`, `try`/`catch` for async errors, and sequential iteration over async results.

## Scenario
A weather app fetches data from a simulated API. Some cities are unknown and throw errors. The app must handle failures gracefully without aborting the entire forecast.

## Instructions
- Fix return types and add missing `async`/`await`.
- Handle failing cities with `try`/`catch` so the loop continues.
- Fetch three cities sequentially (not in parallel).

## Restrictions
- Do not rename variables or functions.
- Do not delete existing code.
- Use `async`/`await` (do not use `.then()`).
- Use `try`/`catch` for error handling.

## Starter Code

```dart
// TODO 1: This uses Future.delayed — mark it async and fix the return type
String fetchWeather(String city) {
  return Future.delayed(
    Duration(milliseconds: 500),
    () {
      if (city == 'Atlantis') throw Exception('City not found in database');
      if (city == 'Gotham') throw Exception('No data available');
      return '${city}: 22°C, Sunny';
    },
  );
}

// TODO 2: Fetch all cities sequentially using async/await
// Fix the return type and add missing keywords
void showForecast(List<String> cities) {
  for (var city in cities) {
    String result = fetchWeather(city); // this gets a Future, not String
    print(result);
  }
}

// TODO 3: Same as showForecast but wrap each fetch in try/catch
// so a failing city doesn't stop the rest
void showForecastSafe(List<String> cities) {
  for (var city in cities) {
    // add try/catch here
    String result = fetchWeather(city);
    print(result);
  }
}

void main() async {
  print('Loading...');
  await showForecast(['Tokyo', 'London', 'Paris']);
  await showForecastSafe(['Tokyo', 'Atlantis', 'Paris', 'Gotham', 'Berlin']);
  print('Done');
}
```

## Expected Output

```
Loading...
Tokyo: 22°C, Sunny
London: 22°C, Sunny
Paris: 22°C, Sunny
Tokyo: 22°C, Sunny
Error: Exception: City not found in database
Paris: 22°C, Sunny
Error: Exception: No data available
Berlin: 22°C, Sunny
Done
```
