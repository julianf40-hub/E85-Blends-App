import { getSessionCookieOptions } from "./_core/cookies";
import { systemRouter } from "./_core/systemRouter";
import { publicProcedure, router } from "./_core/trpc";
import { TRPCError } from "@trpc/server";
import { z } from "zod";
import axios from "axios";
import { COOKIE_NAME } from "../shared/const";

const STATION_SEARCH_RATE_LIMIT_WINDOW_MS = 60_000;
const STATION_SEARCH_RATE_LIMIT_MAX_REQUESTS = 30;
const STATION_SEARCH_CACHE_TTL_MS = 60_000;
const STATION_SEARCH_ERR_CONFIG = "STATION_SEARCH_CONFIG_ERROR";
const STATION_SEARCH_ERR_RATE_LIMIT = "STATION_SEARCH_RATE_LIMITED";
const STATION_SEARCH_ERR_UPSTREAM = "STATION_SEARCH_UPSTREAM_ERROR";

type RateLimitEntry = {
  windowStart: number;
  count: number;
};

type CacheEntry = {
  expiresAt: number;
  data: unknown;
};

const stationSearchRateLimit = new Map<string, RateLimitEntry>();
const stationSearchCache = new Map<string, CacheEntry>();

function getClientIdentifier(headers: Record<string, unknown>): string {
  const forwardedFor = headers["x-forwarded-for"];
  if (typeof forwardedFor === "string" && forwardedFor.trim().length > 0) {
    return forwardedFor.split(",")[0]?.trim() || "unknown";
  }
  if (Array.isArray(forwardedFor) && forwardedFor.length > 0) {
    return String(forwardedFor[0] ?? "unknown");
  }
  return "unknown";
}

function enforceStationSearchRateLimit(clientId: string): void {
  const now = Date.now();
  const current = stationSearchRateLimit.get(clientId);

  if (!current || now - current.windowStart >= STATION_SEARCH_RATE_LIMIT_WINDOW_MS) {
    stationSearchRateLimit.set(clientId, { windowStart: now, count: 1 });
    return;
  }

  if (current.count >= STATION_SEARCH_RATE_LIMIT_MAX_REQUESTS) {
    throw new TRPCError({
      code: "TOO_MANY_REQUESTS",
      message: STATION_SEARCH_ERR_RATE_LIMIT,
    });
  }

  current.count += 1;
  stationSearchRateLimit.set(clientId, current);
}

function buildStationSearchCacheKey(input: {
  latitude: number;
  longitude: number;
  radius: number;
  fuelType: "E85";
}): string {
  return `${input.latitude.toFixed(4)}:${input.longitude.toFixed(4)}:${input.radius}:${input.fuelType}`;
}

function getCachedStationSearch(key: string): unknown | null {
  const now = Date.now();
  const cached = stationSearchCache.get(key);
  if (!cached) return null;
  if (cached.expiresAt <= now) {
    stationSearchCache.delete(key);
    return null;
  }
  return cached.data;
}

function setCachedStationSearch(key: string, data: unknown): void {
  stationSearchCache.set(key, {
    data,
    expiresAt: Date.now() + STATION_SEARCH_CACHE_TTL_MS,
  });
}

export const appRouter = router({
  // if you need to use socket.io, read and register route in server/_core/index.ts, all api should start with '/api/' so that the gateway can route correctly
  system: systemRouter,
  auth: router({
    me: publicProcedure.query((opts) => opts.ctx.user),
    logout: publicProcedure.mutation(({ ctx }) => {
      const cookieOptions = getSessionCookieOptions(ctx.req);
      ctx.res.clearCookie(COOKIE_NAME, { ...cookieOptions, maxAge: -1 });
      return {
        success: true,
      } as const;
    }),
  }),

  // NREL Station API proxy (prevents rate limits and client-side API key exposure)
  stations: router({
    search: publicProcedure
      .input(
        z.object({
          latitude: z.number().min(-90).max(90),
          longitude: z.number().min(-180).max(180),
          radius: z.number().min(1).max(100).default(25),
          fuelType: z.literal("E85").default("E85"),
        })
      )
      .query(async ({ input, ctx }) => {
        const clientId = getClientIdentifier(ctx.req.headers as Record<string, unknown>);
        enforceStationSearchRateLimit(clientId);

        const cacheKey = buildStationSearchCacheKey(input);
        const cached = getCachedStationSearch(cacheKey);
        if (cached) {
          return cached;
        }

        const apiKey = process.env.NREL_API_KEY;
        if (!apiKey || apiKey.trim().length === 0) {
          throw new TRPCError({
            code: "INTERNAL_SERVER_ERROR",
            message: STATION_SEARCH_ERR_CONFIG,
          });
        }

        try {
          const url = "https://developer.nlr.gov/api/alt-fuel-stations/v1/nearest.json";
          const response = await axios.get(url, {
            params: {
              api_key: apiKey,
              latitude: input.latitude,
              longitude: input.longitude,
              radius: input.radius,
              fuel_type: input.fuelType,
              status: "E,P",
              limit: 50,
            },
          });
          setCachedStationSearch(cacheKey, response.data);
          return response.data;
        } catch (error) {
          if (axios.isAxiosError(error) && error.response?.status === 429) {
            throw new TRPCError({
              code: "TOO_MANY_REQUESTS",
              message: STATION_SEARCH_ERR_RATE_LIMIT,
            });
          }
          console.error("[Stations] NREL API request failed");
          throw new TRPCError({
            code: "INTERNAL_SERVER_ERROR",
            message: STATION_SEARCH_ERR_UPSTREAM,
          });
        }
      }),
  }),
});

export type AppRouter = typeof appRouter;

export const __stationSearchTestUtils = {
  errors: {
    config: STATION_SEARCH_ERR_CONFIG,
    rateLimit: STATION_SEARCH_ERR_RATE_LIMIT,
    upstream: STATION_SEARCH_ERR_UPSTREAM,
  },
  reset() {
    stationSearchRateLimit.clear();
    stationSearchCache.clear();
  },
};
