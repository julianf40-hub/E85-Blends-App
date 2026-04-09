import { describe, expect, it, beforeEach, afterEach, vi } from "vitest";
import axios from "axios";
import { appRouter, __stationSearchTestUtils } from "../server/routers";
import type { TrpcContext } from "../server/_core/context";

const ORIGINAL_NREL_API_KEY = process.env.NREL_API_KEY;

function createContext(ip = "127.0.0.1"): TrpcContext {
  return {
    user: null,
    req: {
      headers: {
        "x-forwarded-for": ip,
      },
    } as unknown as TrpcContext["req"],
    res: {} as unknown as TrpcContext["res"],
  };
}

describe("stations.search", () => {
  beforeEach(() => {
    __stationSearchTestUtils.reset();
    vi.restoreAllMocks();
    process.env.NREL_API_KEY = "test_nrel_api_key_for_unit_tests_123456789";
  });

  afterEach(() => {
    process.env.NREL_API_KEY = ORIGINAL_NREL_API_KEY;
  });

  it("rejects invalid latitude via strict bounds", async () => {
    const caller = appRouter.createCaller(createContext());

    await expect(
      caller.stations.search({
        latitude: 120,
        longitude: -112.074,
        radius: 25,
        fuelType: "E85",
      }),
    ).rejects.toMatchObject({ code: "BAD_REQUEST" });
  });

  it("fails when NREL_API_KEY is missing", async () => {
    process.env.NREL_API_KEY = "";
    const caller = appRouter.createCaller(createContext());

    await expect(
      caller.stations.search({
        latitude: 33.4484,
        longitude: -112.074,
        radius: 25,
        fuelType: "E85",
      }),
    ).rejects.toMatchObject({
      code: "INTERNAL_SERVER_ERROR",
      message: __stationSearchTestUtils.errors.config,
    });
  });

  it("returns internal error when upstream NREL request fails", async () => {
    vi.spyOn(axios, "get").mockRejectedValue(new Error("upstream down"));
    const caller = appRouter.createCaller(createContext());

    await expect(
      caller.stations.search({
        latitude: 33.4484,
        longitude: -112.074,
        radius: 25,
        fuelType: "E85",
      }),
    ).rejects.toMatchObject({
      code: "INTERNAL_SERVER_ERROR",
      message: __stationSearchTestUtils.errors.upstream,
    });
  });

  it("maps upstream 429 into stable rate-limit code", async () => {
    vi.spyOn(axios, "get").mockRejectedValue({
      isAxiosError: true,
      response: { status: 429 },
    });
    const caller = appRouter.createCaller(createContext("10.0.0.2"));

    await expect(
      caller.stations.search({
        latitude: 33.4484,
        longitude: -112.074,
        radius: 25,
        fuelType: "E85",
      }),
    ).rejects.toMatchObject({
      code: "TOO_MANY_REQUESTS",
      message: __stationSearchTestUtils.errors.rateLimit,
    });
  });

  it("uses short TTL cache for repeated identical requests", async () => {
    const mockData = { fuel_stations: [{ id: 1, station_name: "Test" }] };
    const getSpy = vi.spyOn(axios, "get").mockResolvedValue({ data: mockData });
    const caller = appRouter.createCaller(createContext());

    const first = await caller.stations.search({
      latitude: 33.4484,
      longitude: -112.074,
      radius: 25,
      fuelType: "E85",
    });
    const second = await caller.stations.search({
      latitude: 33.4484,
      longitude: -112.074,
      radius: 25,
      fuelType: "E85",
    });

    expect(first).toEqual(mockData);
    expect(second).toEqual(mockData);
    expect(getSpy).toHaveBeenCalledTimes(1);
  });

  it("applies lightweight per-client rate limiting", async () => {
    vi.spyOn(axios, "get").mockResolvedValue({ data: { fuel_stations: [] } });
    const caller = appRouter.createCaller(createContext("10.0.0.1"));

    for (let i = 0; i < 30; i += 1) {
      await caller.stations.search({
        latitude: 33.4484,
        longitude: -112.074,
        radius: 25,
        fuelType: "E85",
      });
    }

    await expect(
      caller.stations.search({
        latitude: 33.4484,
        longitude: -112.074,
        radius: 25,
        fuelType: "E85",
      }),
    ).rejects.toMatchObject({
      code: "TOO_MANY_REQUESTS",
      message: __stationSearchTestUtils.errors.rateLimit,
    });
  });
});
