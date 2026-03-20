// Domain models for API results.
// These types are used by the app - no OpenAPI-generated types leak outside ApiService.

/// Result of executing a stored plan.
class ExecuteStoredPlanResult {
  const ExecuteStoredPlanResult({required this.executed, this.reason});

  final bool executed;
  final String? reason;
}

/// A single action in an execution plan (app domain type).
class PlanActionInput {
  const PlanActionInput({required this.tool, this.arguments = const {}});

  final String tool;
  final Map<String, String> arguments;
}

/// An execution plan (app domain type).
class ExecutionPlanInput {
  const ExecutionPlanInput({
    required this.actions,
    this.emptyReason,
    required this.generatedAt,
  });

  final List<PlanActionInput> actions;
  final String? emptyReason;
  final String generatedAt;
}
