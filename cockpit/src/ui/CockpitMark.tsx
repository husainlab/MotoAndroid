import React from 'react';
import Svg, { Circle, Line } from 'react-native-svg';

interface CockpitMarkProps {
  size?: number;
  color?: string;
}

/**
 * Single-color Cockpit logomark: precision twin aviation / motorcycle HUD bars
 * linked through a central radar reticle. High visibility at micro & macro scale.
 */
export function CockpitMark({ size = 28, color = '#FF5A1F' }: CockpitMarkProps) {
  return (
    <Svg width={size} height={size} viewBox="0 0 100 100" accessibilityLabel="Cockpit mark">
      {/* Outer horizon wing bars */}
      <Line
        x1={12}
        y1={50}
        x2={36}
        y2={50}
        stroke={color}
        strokeWidth={10}
        strokeLinecap="round"
      />
      <Line
        x1={64}
        y1={50}
        x2={88}
        y2={50}
        stroke={color}
        strokeWidth={10}
        strokeLinecap="round"
      />
      {/* Central cockpit reticle */}
      <Circle
        cx={50}
        cy={50}
        r={18}
        stroke={color}
        strokeWidth={8}
        fill="none"
      />
      <Circle cx={50} cy={50} r={5} fill={color} />
      {/* Upper pitch indicator */}
      <Line
        x1={50}
        y1={16}
        x2={50}
        y2={26}
        stroke={color}
        strokeWidth={8}
        strokeLinecap="round"
      />
    </Svg>
  );
}

export const PillionMark = CockpitMark;
