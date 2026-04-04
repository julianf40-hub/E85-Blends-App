import { getSessionCookieOptions } from "./_core/cookies";
import { systemRouter } from "./_core/systemRouter";
import { publicProcedure, router } from "./_core/trpc";
import { z } from "zod";
import axios from "axios";
import { COOKIE_NAME } from "../shared/const";

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
          latitude: z.number(),
          longitude: z.number(),
          radius: z.number().default(25),
          fuelType: z.string().default("E85"),
        })
      )
      .query(async ({ input }) => {
        try {
          // Use server-only env variable — NOT exposed to client
          const apiKey = process.env.NREL_API_KEY || "DEMO_KEY";
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
          return response.data;
        } catch (error) {
          console.error("NREL API error:", error);
          throw new Error("Failed to fetch stations from NREL API");
        }
      }),
  }),
});

export type AppRouter = typeof appRouter;
