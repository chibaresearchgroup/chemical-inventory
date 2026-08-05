import {
  Activity,
  AlertTriangle,
  BarChart3,
  BookOpen,
  Camera,
  ClipboardList,
  GitBranch,
  FlaskConical,
  LayoutDashboard,
  MapPin,
  QrCode,
  Microscope,
} from 'lucide-react'

/** The side-nav list, kept in one place so anything that needs "every page in
 *  the app" (the sidebar, the command palette) reads the same list rather
 *  than maintaining a second copy that drifts. */
export const NAV = [
  { to: '/', label: 'Dashboard', icon: LayoutDashboard, end: true },
  { to: '/inventory', label: 'Inventory', icon: FlaskConical, end: false },
  { to: '/stocktake', label: 'Stocktake', icon: Camera, end: false },
  { to: '/locations', label: 'Locations', icon: MapPin, end: false },
  { to: '/project-map', label: 'Project Map', icon: GitBranch, end: false },
  { to: '/operations', label: 'Operations', icon: ClipboardList, end: false },
  { to: '/equipment', label: 'Equipment', icon: Microscope, end: false },
  { to: '/sops', label: 'SOPs', icon: BookOpen, end: false },
  { to: '/incidents', label: 'Incidents', icon: AlertTriangle, end: false },
  { to: '/analytics', label: 'Analytics', icon: BarChart3, end: false },
  { to: '/activity', label: 'Activity', icon: Activity, end: false },
  { to: '/labels', label: 'QR labels', icon: QrCode, end: false },
]
