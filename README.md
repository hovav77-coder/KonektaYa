# Property Ya

MVP funcional para conectar propiedades disponibles en Panama con personas o brokers que buscan comprar o alquilar mediante matching automatico.

## Stack

- Next.js App Router
- React
- API routes
- SQLite local con `better-sqlite3`
- CSS propio responsive
- Listo para desplegar en Vercel

## Correr localmente

```bash
npm install
npm run dev
```

Luego abre:

```text
http://localhost:3000
```

## Desplegar en Vercel

1. Sube este proyecto a GitHub, GitLab o Bitbucket.
2. Entra a Vercel y selecciona **Add New Project**.
3. Importa el repositorio.
4. Vercel detectara Next.js automaticamente.
5. Usa estos comandos:

```text
Install Command: npm install
Build Command: npm run build
Development Command: npm run dev
```

6. Haz deploy.

El archivo `vercel.json` ya deja esos valores preparados.

## Nota importante sobre la base de datos en Vercel

Este MVP usa SQLite para mantenerlo simple. En local, la base se crea en:

```text
data/property-ya.db
```

En Vercel, la app usa automaticamente una carpeta temporal:

```text
/tmp/property-ya/property-ya.db
```

Eso permite que el prototipo funcione en Vercel, pero los datos no deben considerarse persistentes para produccion. Para una version real, el siguiente paso recomendado es mover la base de datos a Supabase, Neon, Postgres o Vercel Postgres.

## Pantallas incluidas

- Inicio: propuesta de valor y accesos principales.
- Registrar propiedad: formulario simple para duenos.
- Registrar busqueda: formulario para clientes finales o brokers.
- Flujo visual: proceso de seis pasos desde registro hasta fee.
- Matches demo: listado de coincidencias con score, tipo de match y contacto bloqueado hasta aprobacion.
- Dashboard admin: metricas basicas, revision manual de matches y control de liberacion de contacto.

## Revision manual de matches

Los datos de contacto no se muestran al publico cuando se crea un match. Primero aparece:

```text
Match encontrado. Para liberar contacto debe aceptar terminos y fee de manejo.
```

Desde `/admin` se puede:

- Aprobar match
- Rechazar match
- Marcar como contactado
- Marcar como cerrado

## Reglas de matching

- Misma operacion: +25 puntos
- Mismo tipo de propiedad: +25 puntos
- Misma zona: +20 puntos
- Precio dentro del presupuesto: +20 puntos
- Metraje compatible: +10 puntos

Si el score es mayor o igual a 70, se crea un match.

## Variables de entorno

No se requiere ninguna variable para correr el MVP.

Opcionalmente puedes definir:

```text
PROPERTY_YA_DB_DIR=/ruta/custom
```

Esto cambia la carpeta donde se crea la base SQLite.
