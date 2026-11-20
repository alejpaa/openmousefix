# OpenMouseFix

Utilidad de barra de menús para macOS, de código abierto, que arregla el ratón: desplazamiento suave, dirección de la rueda independiente del trackpad y botones laterales/central con gestos.

## Características

- Desplazamiento suave de la rueda con velocidad, suavidad y aceleración ajustables.
- Invertir la dirección del ratón y del trackpad por separado.
- Botones 4, 5 y central: acción al hacer clic (atrás, adelante, Mission Control, App Exposé, mostrar escritorio, Launchpad, cambiar de escritorio, clic central…).
- Gestos al mantener pulsado y arrastrar: cambiar de escritorio, Mission Control y App Exposé con la misma animación interactiva que el trackpad; el resto de acciones con umbral configurable.
- Opción de abrir al iniciar sesión.

## Requisitos

- macOS 13 o superior.
- Command Line Tools (`xcode-select --install`). No hace falta Xcode.

## Instalar

Abre Terminal y pega:

```bash
curl -fsSL https://raw.githubusercontent.com/alejpaa/openmousefix/main/install.sh | bash
```

El mismo comando sirve para actualizar. Descarga la última versión publicada (o, si no hay ninguna, la compila desde el código fuente), la copia a `/Applications` y la abre.

Para desinstalar:

```bash
curl -fsSL https://raw.githubusercontent.com/alejpaa/openmousefix/main/install.sh | bash -s -- --uninstall
```

## Compilar desde el código fuente

```bash
./build.sh            # genera build/OpenMouseFix.app
./build.sh install    # además la copia a /Applications
UNIVERSAL=1 ./build.sh   # binario universal (arm64 + x86_64)
```

## Permiso de Accesibilidad

Al abrirla por primera vez, la app solicita acceso en Ajustes del Sistema → Privacidad y seguridad → Accesibilidad. Actívala para OpenMouseFix; la app empieza a funcionar sola en cuanto se concede.

Como la app se firma ad-hoc, cada recompilación cambia su firma y macOS puede ignorar el permiso anterior. El instalador lo restablece automáticamente para que macOS lo vuelva a pedir. Si compilas a mano y deja de funcionar, elimina OpenMouseFix de la lista de Accesibilidad (botón −) y vuelve a añadirla.

## Notas

- El cambio de escritorio usa los atajos ⌃← / ⌃→, que deben estar activados en Ajustes del Sistema → Teclado → Atajos de teclado → Mission Control.

## Limitaciones conocidas

- El Magic Mouse se trata como un trackpad.

## Proyectos similares

Inspirado en [LinearMouse](https://github.com/linearmouse/linearmouse), [Mos](https://github.com/Caldis/Mos) y [Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix).

## Publicar una versión

Sube una etiqueta y GitHub Actions compila la app universal y crea la release:

```bash
git tag v0.1.0 && git push origin v0.1.0
```

## Licencia

MIT. Consulta [LICENSE](LICENSE).
