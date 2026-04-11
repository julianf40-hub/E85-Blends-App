import { Redirect } from "expo-router";

/**
 * Root index file to handle the initial app entry.
 * Redirects to the (tabs) group, which then handles the logic
 * for onboarding vs. main app in its own layout or via RootLayout.
 */
export default function Index() {
  return <Redirect href="/(tabs)/calculator" />;
}
