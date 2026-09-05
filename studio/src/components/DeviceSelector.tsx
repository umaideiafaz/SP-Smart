// ============================================================
// SP Smart Studio — DeviceSelector Component
// ============================================================
import { Monitor, Volume2 } from 'lucide-react';
import clsx from 'clsx';
import type { DeviceInfo } from '@/types';

interface DeviceSelectorProps {
  label:      string;
  type:       'video' | 'audio';
  devices:    DeviceInfo[];
  value?:     string;           // DeviceInfo.id selecionado
  onChange:   (deviceId: string | undefined) => void;
  disabled?:  boolean;
  className?: string;
}

export function DeviceSelector({
  label, type, devices, value, onChange, disabled, className,
}: DeviceSelectorProps) {
  const Icon = type === 'video' ? Monitor : Volume2;
  const accentColor = type === 'video' ? 'text-blue-400' : 'text-purple-400';

  return (
    <div className={clsx('flex flex-col gap-1', className)}>
      <label className="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-widest text-gray-400">
        <Icon size={12} className={accentColor} />
        {label}
      </label>

      <div className="relative">
        <select
          value={value ?? ''}
          disabled={disabled || devices.length === 0}
          onChange={(e) => onChange(e.target.value || undefined)}
          className={clsx(
            'w-full appearance-none rounded-md border px-3 py-2 pr-8 text-sm',
            'bg-gray-900 text-gray-100 transition-colors',
            'focus:outline-none focus:ring-2 focus:ring-offset-1 focus:ring-offset-gray-900',
            type === 'video'
              ? 'border-blue-800/50 focus:ring-blue-500'
              : 'border-purple-800/50 focus:ring-purple-500',
            (disabled || devices.length === 0) && 'cursor-not-allowed opacity-40',
          )}
        >
          <option value="">
            {devices.length === 0 ? '— Nenhum dispositivo encontrado —' : '— Selecionar saída —'}
          </option>

          {/* Agrupa: auto-fallbacks primeiro, depois físicos */}
          {devices.filter(d => d.is_auto).length > 0 && (
            <optgroup label="Automático (SO)">
              {devices.filter(d => d.is_auto).map(d => (
                <option key={d.id} value={d.id}>
                  {d.display_name}
                </option>
              ))}
            </optgroup>
          )}

          {devices.filter(d => !d.is_auto).length > 0 && (
            <optgroup label="Hardware Físico">
              {devices.filter(d => !d.is_auto).map(d => (
                <option key={d.id} value={d.id}>
                  {d.display_name}
                  {d.element_type !== d.display_name ? ` (${d.element_type})` : ''}
                </option>
              ))}
            </optgroup>
          )}
        </select>

        {/* Chevron customizado */}
        <div className="pointer-events-none absolute inset-y-0 right-2 flex items-center">
          <svg className="h-4 w-4 text-gray-500" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
          </svg>
        </div>
      </div>

      {/* Device info chip */}
      {value && (() => {
        const dev = devices.find(d => d.id === value);
        return dev ? (
          <p className="text-[10px] text-gray-600 truncate" title={dev.element_type}>
            ▸ {dev.element_type}
          </p>
        ) : null;
      })()}
    </div>
  );
}
