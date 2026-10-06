#!/usr/bin/env python3
"""Renderiza docker-compose.yml (y, con --redirect, su override) SIN Docker: expande ${VAR}, ${VAR:-d},
${VAR-d} y ${VAR:?msg} con el entorno del proceso (anidados incluidos) y fusiona como compose (las
listas se concatenan; `image` y `command` se reemplazan). Imprime JSON canónico: sirve para comparar por
hash lo que ve `docker compose config` sin correr Docker. Solo para las pruebas del instalador.

  render-compose.py [--redirect] [--base RUTA] [--override RUTA]
Sale con 3 y un mensaje por stderr si una ${VAR:?msg} no tiene valor.
"""
import argparse, hashlib, json, os, sys
import yaml


class Falta(Exception):
    pass


def expandir(s, env):
    out, i = [], 0
    while i < len(s):
        if s.startswith("$$", i):
            out.append("$"); i += 2; continue
        if not s.startswith("${", i):
            out.append(s[i]); i += 1; continue
        depth, j = 1, i + 2
        while j < len(s) and depth:
            if s.startswith("${", j):
                depth += 1; j += 2; continue
            if s[j] == "}":
                depth -= 1
            j += 1
        cuerpo = s[i + 2:j - 1]
        i = j
        for op in (":-", ":?", "-", "?"):
            k = cuerpo.find(op)
            if k > 0:
                nombre, resto = cuerpo[:k], cuerpo[k + len(op):]
                break
        else:
            nombre, op, resto = cuerpo, "", ""
        valor = env.get(nombre)
        vacio = valor is None or (op.startswith(":") and valor == "")
        if op in ("", ):
            out.append(valor or "")
        elif op in (":-", "-"):
            out.append(expandir(resto, env) if vacio else valor)
        else:  # :? y ?
            if vacio:
                raise Falta(f"{nombre}: {resto}")
            out.append(valor)
    return "".join(out)


def recorrer(x, env):
    if isinstance(x, str):
        return expandir(x, env)
    if isinstance(x, list):
        return [recorrer(v, env) for v in x]
    if isinstance(x, dict):
        return {k: recorrer(v, env) for k, v in x.items()}
    return x


REEMPLAZA = {"image", "command"}


def fusionar(base, sobre, clave=None):
    if isinstance(base, dict) and isinstance(sobre, dict):
        res = dict(base)
        for k, v in sobre.items():
            res[k] = fusionar(base[k], v, k) if k in base else v
        return res
    if isinstance(base, list) and isinstance(sobre, list) and clave not in REEMPLAZA:
        return base + sobre
    return sobre


def main():
    ap = argparse.ArgumentParser()
    aqui = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--redirect", action="store_true")
    ap.add_argument("--base", default=os.path.join(aqui, "..", "docker-compose.yml"))
    ap.add_argument("--override", default=os.path.join(aqui, "..", "docker-compose.redirect.yml"))
    ap.add_argument("--hash", action="store_true", help="imprime solo el sha256 del JSON canónico")
    a = ap.parse_args()
    cfg = yaml.safe_load(open(a.base))
    if a.redirect:
        cfg = fusionar(cfg, yaml.safe_load(open(a.override)))
    try:
        cfg = recorrer(cfg, dict(os.environ))
    except Falta as e:
        print(f"falta variable requerida: {e}", file=sys.stderr)
        sys.exit(3)
    texto = json.dumps(cfg, sort_keys=True, indent=1)
    print(hashlib.sha256(texto.encode()).hexdigest() if a.hash else texto)


if __name__ == "__main__":
    main()
