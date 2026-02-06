interface PawIconProps {
  size?: number;
  className?: string;
}

export default function PawIcon({
  size = 32,
  className = "",
}: PawIconProps) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 100 100"
      className={className}
      aria-hidden="true"
    >
      <ellipse cx="50" cy="65" rx="25" ry="20" fill="#4A2C17" />
      <ellipse
        cx="26"
        cy="36"
        rx="9.5"
        ry="11.5"
        fill="#4A2C17"
        transform="rotate(-12 26 36)"
      />
      <ellipse
        cx="42"
        cy="30"
        rx="9"
        ry="11"
        fill="#4A2C17"
        transform="rotate(-4 42 30)"
      />
      <ellipse
        cx="58"
        cy="30"
        rx="9.2"
        ry="11.2"
        fill="#FF69B4"
        transform="rotate(6 58 30)"
      />
      <ellipse
        cx="74"
        cy="36"
        rx="9.6"
        ry="11.4"
        fill="#4A2C17"
        transform="rotate(14 74 36)"
      />
    </svg>
  );
}
