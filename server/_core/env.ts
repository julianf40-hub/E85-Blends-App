const JWT_PLACEHOLDERS = new Set([
  "changeme",
  "jwt_secret",
  "placeholder",
  "replace-me",
  "secret",
  "test-secret",
  "your-secret-key",
  "your_jwt_secret_here",
]);

function isTestEnvironment(): boolean {
  return process.env.NODE_ENV === "test" || process.env.VITEST === "true";
}

function validateJwtSecret(secret: string): void {
  if (isTestEnvironment()) return;

  const trimmed = secret.trim();
  const lowered = trimmed.toLowerCase();

  const hasPlaceholderToken =
    lowered.includes("your_") ||
    lowered.includes("your-") ||
    lowered.includes("<") ||
    lowered.includes(">") ||
    lowered.includes("example");

  const isWeakLength = trimmed.length < 32;

  if (!trimmed || JWT_PLACEHOLDERS.has(lowered) || hasPlaceholderToken || isWeakLength) {
    throw new Error(
      "[Config] Invalid JWT_SECRET. Set a strong secret (>= 32 chars) before starting the server. " +
        "Example: openssl rand -base64 32",
    );
  }
}

const cookieSecret = process.env.JWT_SECRET ?? "";
validateJwtSecret(cookieSecret);

export const ENV = {
  appId: process.env.VITE_APP_ID ?? "",
  cookieSecret,
  databaseUrl: process.env.DATABASE_URL ?? "",
  oAuthServerUrl: process.env.OAUTH_SERVER_URL ?? "",
  ownerOpenId: process.env.OWNER_OPEN_ID ?? "",
  isProduction: process.env.NODE_ENV === "production",
  forgeApiUrl: process.env.BUILT_IN_FORGE_API_URL ?? "",
  forgeApiKey: process.env.BUILT_IN_FORGE_API_KEY ?? "",
};
