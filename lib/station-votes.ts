/**
 * Station E85 Availability Votes
 * Community voting on whether a station actually sells E85/flex fuel.
 * Votes are stored locally per device. In a future server-backed version
 * these would be aggregated across all users.
 */
import AsyncStorage from "@react-native-async-storage/async-storage";

const STORAGE_KEY = "e85_station_votes";

export type VoteType = "yes" | "no";

export interface StationVote {
  stationId: string;
  /** User's own vote for this station (undefined = not voted) */
  userVote?: VoteType;
  /** Cumulative yes votes (starts at 0 for new stations) */
  yesCount: number;
  /** Cumulative no votes */
  noCount: number;
  /** ISO timestamp of last vote */
  lastVoted?: string;
}

type VoteStore = Record<string, StationVote>;

async function loadStore(): Promise<VoteStore> {
  try {
    const raw = await AsyncStorage.getItem(STORAGE_KEY);
    return raw ? JSON.parse(raw) : {};
  } catch {
    return {};
  }
}

async function saveStore(store: VoteStore): Promise<void> {
  await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(store));
}

/** Get vote data for a single station */
export async function getStationVote(stationId: string): Promise<StationVote> {
  const store = await loadStore();
  return store[stationId] ?? { stationId, yesCount: 0, noCount: 0 };
}

/** Get vote data for multiple stations at once */
export async function getStationVotes(
  stationIds: string[]
): Promise<Record<string, StationVote>> {
  const store = await loadStore();
  const result: Record<string, StationVote> = {};
  for (const id of stationIds) {
    result[id] = store[id] ?? { stationId: id, yesCount: 0, noCount: 0 };
  }
  return result;
}

/**
 * Cast or retract a vote for a station.
 * Tapping the same vote again removes it (toggle behaviour).
 */
export async function castVote(
  stationId: string,
  vote: VoteType
): Promise<StationVote> {
  const store = await loadStore();
  const current = store[stationId] ?? { stationId, yesCount: 0, noCount: 0 };

  const isSameVote = current.userVote === vote;

  if (isSameVote) {
    // Retract the vote
    const updated: StationVote = {
      ...current,
      userVote: undefined,
      yesCount: vote === "yes" ? Math.max(0, current.yesCount - 1) : current.yesCount,
      noCount: vote === "no" ? Math.max(0, current.noCount - 1) : current.noCount,
      lastVoted: new Date().toISOString(),
    };
    store[stationId] = updated;
    await saveStore(store);
    return updated;
  }

  // Undo previous vote if switching
  let yesCount = current.yesCount;
  let noCount = current.noCount;
  if (current.userVote === "yes") yesCount = Math.max(0, yesCount - 1);
  if (current.userVote === "no") noCount = Math.max(0, noCount - 1);

  // Apply new vote
  if (vote === "yes") yesCount += 1;
  if (vote === "no") noCount += 1;

  const updated: StationVote = {
    ...current,
    userVote: vote,
    yesCount,
    noCount,
    lastVoted: new Date().toISOString(),
  };
  store[stationId] = updated;
  await saveStore(store);
  return updated;
}

/** Confidence score 0–100 based on vote ratio */
export function getConfidenceScore(vote: StationVote): number {
  const total = vote.yesCount + vote.noCount;
  if (total === 0) return -1; // no data
  return Math.round((vote.yesCount / total) * 100);
}
