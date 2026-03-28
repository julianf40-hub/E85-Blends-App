/** @type {const} */
const themeColors = {
  // Primary brand green — bright on OLED black for strong contrast
  primary:    { light: '#16A34A', dark: '#22C55E' },
  // OLED true black background — saves battery, looks stunning on OLED panels
  background: { light: '#F8FAFC', dark: '#000000' },
  // Slightly lifted surface for cards — just enough separation without grey wash
  surface:    { light: '#FFFFFF', dark: '#0D0D0D' },
  // Primary text
  foreground: { light: '#0F172A', dark: '#F1F5F9' },
  // Secondary / muted text
  muted:      { light: '#64748B', dark: '#8A9AB0' },
  // Borders — very subtle on OLED so cards feel borderless
  border:     { light: '#E2E8F0', dark: '#1C1C1C' },
  // Semantic states
  success:    { light: '#16A34A', dark: '#4ADE80' },
  warning:    { light: '#F59E0B', dark: '#FBBF24' },
  error:      { light: '#EF4444', dark: '#F87171' },
  accent:     { light: '#D97706', dark: '#F59E0B' },
};

module.exports = { themeColors };
