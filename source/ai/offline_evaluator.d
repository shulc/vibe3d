module ai.offline_evaluator;

import std.math : isFinite;

import ai.interaction : AiAdvisorDecision, AiCandidate;
import ai.interaction_log : AiInteractionLogRecord;

struct AiOfflineBaselinePrediction {
    int candidateIndex = -1;
    string candidateId = "";

    bool present() const {
        return candidateIndex >= 0 || candidateId.length != 0;
    }
}

struct AiOfflineEvaluationMetrics {
    size_t total = 0;
    size_t evaluated = 0;
    size_t missingWinner = 0;
    size_t correct = 0;
    double accuracy = 0.0;
}

struct AiOfflineEvaluationGroup {
    string groupId = "";
    AiOfflineEvaluationMetrics metrics;
}

struct AiOfflineEvaluationReport {
    AiOfflineEvaluationMetrics overall;
    AiOfflineEvaluationGroup[] byGroup;
}

AiOfflineBaselinePrediction predictAiOfflineBaselineWinner(
    const ref AiInteractionLogRecord record) {
    return predictAiOfflineBaselineWinner(record.candidates);
}

AiOfflineBaselinePrediction predictAiOfflineBaselineWinner(
    const(AiCandidate)[] candidates) {
    if (candidates.length == 0)
        return AiOfflineBaselinePrediction();

    foreach (i, ref candidate; candidates) {
        if (candidate.isExplicitModifierChoice)
            return predictionForCandidate(candidates, cast(int)i);
    }

    immutable scoredIndex = bestScoredCandidateIndex(candidates);
    if (scoredIndex >= 0)
        return predictionForCandidate(candidates, scoredIndex);

    foreach (i, ref candidate; candidates) {
        if (candidate.isDefaultWinner)
            return predictionForCandidate(candidates, cast(int)i);
    }

    return predictionForCandidate(candidates, 0);
}

AiOfflineBaselinePrediction replayAiOfflineAdvisorDecision(
    const ref AiInteractionLogRecord record) {
    return replayAiOfflineAdvisorDecision(record.candidates,
                                          record.advisorDecision);
}

AiOfflineBaselinePrediction replayAiOfflineAdvisorDecision(
    const(AiCandidate)[] candidates,
    AiAdvisorDecision advisorDecision) {
    immutable advisorIndex =
        advisorCandidateIndex(candidates, advisorDecision);
    if (advisorIndex < 0)
        return AiOfflineBaselinePrediction();
    return predictionForCandidate(candidates, advisorIndex);
}

AiOfflineEvaluationReport evaluateAiOfflineBaseline(
    const(AiInteractionLogRecord)[] records) {
    AiOfflineEvaluationReport report;
    size_t[string] groupIndexById;

    foreach (ref record; records) {
        auto groupMetrics = metricsForGroup(report.byGroup, groupIndexById,
                                            record.groupId);
        auto prediction = predictAiOfflineBaselineWinner(record);

        updateMetrics(report.overall, record, prediction);
        updateMetrics(*groupMetrics, record, prediction);
    }

    finalizeMetrics(report.overall);
    foreach (ref group; report.byGroup)
        finalizeMetrics(group.metrics);
    return report;
}

private int advisorCandidateIndex(const(AiCandidate)[] candidates,
                                  AiAdvisorDecision decision) {
    if (decision.candidateId.length) {
        foreach (i, ref candidate; candidates) {
            if (candidate.id == decision.candidateId)
                return cast(int)i;
        }
        return -1;
    }

    if (decision.candidateIndex < 0)
        return -1;
    immutable index = cast(size_t)decision.candidateIndex;
    return index < candidates.length ? decision.candidateIndex : -1;
}

private int bestScoredCandidateIndex(const(AiCandidate)[] candidates) {
    int bestIndex = -1;
    foreach (i, ref candidate; candidates) {
        if (!hasComparableScore(candidate))
            continue;
        if (bestIndex < 0 ||
            candidateScoreLess(candidate, candidates[cast(size_t)bestIndex]))
            bestIndex = cast(int)i;
    }
    return bestIndex;
}

private bool hasComparableScore(const ref AiCandidate candidate) {
    return candidate.screenDist.isFinite ||
        candidate.worldDist.isFinite ||
        candidate.priorityFromCurrentRules.isFinite;
}

private bool candidateScoreLess(const ref AiCandidate lhs,
                                const ref AiCandidate rhs) {
    immutable lhsScreenRank = lhs.screenDist.isFinite ? 0 : 1;
    immutable rhsScreenRank = rhs.screenDist.isFinite ? 0 : 1;
    if (lhsScreenRank != rhsScreenRank)
        return lhsScreenRank < rhsScreenRank;
    if (lhs.screenDist.isFinite && lhs.screenDist != rhs.screenDist)
        return lhs.screenDist < rhs.screenDist;

    immutable lhsWorldRank = lhs.worldDist.isFinite ? 0 : 1;
    immutable rhsWorldRank = rhs.worldDist.isFinite ? 0 : 1;
    if (lhsWorldRank != rhsWorldRank)
        return lhsWorldRank < rhsWorldRank;
    if (lhs.worldDist.isFinite && lhs.worldDist != rhs.worldDist)
        return lhs.worldDist < rhs.worldDist;

    immutable lhsPriorityRank =
        lhs.priorityFromCurrentRules.isFinite ? 0 : 1;
    immutable rhsPriorityRank =
        rhs.priorityFromCurrentRules.isFinite ? 0 : 1;
    if (lhsPriorityRank != rhsPriorityRank)
        return lhsPriorityRank < rhsPriorityRank;
    if (lhs.priorityFromCurrentRules.isFinite &&
        lhs.priorityFromCurrentRules != rhs.priorityFromCurrentRules)
        return lhs.priorityFromCurrentRules < rhs.priorityFromCurrentRules;

    return false;
}

private AiOfflineBaselinePrediction predictionForCandidate(
    const(AiCandidate)[] candidates,
    int index) {
    AiOfflineBaselinePrediction prediction;
    prediction.candidateIndex = index;
    prediction.candidateId = candidates[cast(size_t)index].id;
    return prediction;
}

private AiOfflineEvaluationMetrics* metricsForGroup(
    ref AiOfflineEvaluationGroup[] groups,
    ref size_t[string] groupIndexById,
    string groupId) {
    if (auto existing = groupId in groupIndexById)
        return &groups[*existing].metrics;

    groupIndexById[groupId] = groups.length;
    groups ~= AiOfflineEvaluationGroup(groupId);
    return &groups[$ - 1].metrics;
}

private void updateMetrics(ref AiOfflineEvaluationMetrics metrics,
                           const ref AiInteractionLogRecord record,
                           const ref AiOfflineBaselinePrediction prediction) {
    ++metrics.total;

    if (expectedWinnerIndex(record) < 0) {
        ++metrics.missingWinner;
        return;
    }

    ++metrics.evaluated;
    if (prediction.candidateId == record.appliedWinnerId)
        ++metrics.correct;
}

private int expectedWinnerIndex(const ref AiInteractionLogRecord record) {
    if (record.appliedWinnerId.length == 0)
        return -1;

    foreach (i, ref candidate; record.candidates) {
        if (candidate.id == record.appliedWinnerId)
            return cast(int)i;
    }
    return -1;
}

private void finalizeMetrics(ref AiOfflineEvaluationMetrics metrics) {
    metrics.accuracy = metrics.evaluated == 0
        ? 0.0
        : cast(double)metrics.correct / cast(double)metrics.evaluated;
}
