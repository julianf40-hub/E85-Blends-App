export const CRON_SECRET_HEADER = "x-85blends-cron-secret";
export const MIN_CRON_SECRET_LENGTH = 32;

export interface WorkerAuthConfig {
  serviceRoleKey: string;
  cronSecret: string;
}

export function constantTimeEqual(a: string, b: string): boolean {
  const len = Math.max(a.length, b.length, 1);
  let diff = a.length === b.length ? 0 : 1;
  for (let i = 0; i < len; i++) diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  return diff === 0;
}

export function bearerToken(headers: Headers): string {
  const value = headers.get("authorization")?.trim() ?? "";
  return value.toLowerCase().startsWith("bearer ") ? value.slice(7).trim() : "";
}

export function isAuthorizedWorkerCall(headers: Headers, config: WorkerAuthConfig): boolean {
  const presentedCronSecret = headers.get(CRON_SECRET_HEADER)?.trim() ?? "";
  const cronOk = config.cronSecret.length >= MIN_CRON_SECRET_LENGTH &&
    presentedCronSecret.length > 0 &&
    constantTimeEqual(config.cronSecret, presentedCronSecret);

  const presentedBearer = bearerToken(headers);
  const bearerOk = config.serviceRoleKey.length > 0 &&
    presentedBearer.length > 0 &&
    constantTimeEqual(config.serviceRoleKey, presentedBearer);

  return cronOk || bearerOk;
}
