import ntuShield from '../assets/ntu-shield.png'
import { LAB_NAME, LAB_SUBTITLE } from '../lib/config'
import { cx } from '../lib/utils'

/**
 * A generic flask mark — this deployment doesn't have the lab's own logo
 * artwork yet, so it renders inline instead of shipping another group's icon
 * under a different name. Swap in a real asset (see Logo() below) once one
 * exists.
 */
export function Logo({ className }: { className?: string }) {
  return (
    <span
      className={cx(
        'inline-flex shrink-0 items-center justify-center overflow-hidden rounded-[28%] bg-[#0b1830]',
        className ?? 'h-8 w-8',
      )}
    >
      <svg viewBox="0 0 24 24" className="h-[60%] w-[60%]" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path
          d="M9.5 2.5h5M10 2.5v6.2l-5.2 9.3A2 2 0 0 0 6.5 21h11a2 2 0 0 0 1.7-3l-5.2-9.3V2.5"
          stroke="url(#logo-grad)"
          strokeWidth="1.6"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path d="M7.8 14.5h8.4" stroke="url(#logo-grad)" strokeWidth="1.6" strokeLinecap="round" />
        <defs>
          <linearGradient id="logo-grad" x1="4" y1="2.5" x2="20" y2="21" gradientUnits="userSpaceOnUse">
            <stop stopColor="#60a5fa" />
            <stop offset="1" stopColor="#a78bfa" />
          </linearGradient>
        </defs>
      </svg>
    </span>
  )
}

export function Wordmark({ compact = false }: { compact?: boolean }) {
  return (
    <div className="flex items-center gap-2.5">
      <Logo />
      {!compact && (
        <div className="leading-tight">
          <div className="text-[15px] font-extrabold tracking-tight text-ink-900 dark:text-ink-50">
            {LAB_NAME}
          </div>
          <div className="text-[10px] font-medium leading-tight text-ink-400">{LAB_SUBTITLE}</div>
        </div>
      )}
    </div>
  )
}

/**
 * The university crest, cropped from the file the group provided — this is
 * NTU's own logo, used here only to credit the university as the lab's home
 * institution, not to imply the app is an official NTU product.
 */
export function NtuBadge({ className }: { className?: string }) {
  return (
    <div className={cx('inline-flex items-center gap-1.5', className)}>
      <img src={ntuShield} alt="Nanyang Technological University" className="h-5 w-auto" draggable={false} />
      <span className="text-[11px] font-bold leading-none tracking-wide text-ink-500 dark:text-ink-400">
        NTU SINGAPORE
      </span>
    </div>
  )
}
