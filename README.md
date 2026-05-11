# mapc2022_pcs5703

Esqueleto JaCaMo para o **2º Exercício Prático** de **PCS 5703 — Sistemas Multi-Agentes** (1º Quadrimestre de 2026, Escola Politécnica da USP).

Implementa um time de agentes para o **Multi-Agent Programming Contest 2022** (cenário *Agents Assemble II*), conforme exigido pelo enunciado, usando:

- **Jason** (plataforma de agentes BDI) — referência [4]
- **MOISE+** (modelo organizacional) — referência [3]
- **JaCaMo** (arcabouço integrador) — referência [2]
- **EISMASSim** (ponte EIS para o servidor MASSim 2022) — referência [6]

## Estrutura do projeto

```
mapc2022_pcs5703/
├── mapc2022.jcm              # arquivo principal: declara MAS, agentes, env e org
├── build.gradle              # build Gradle (chama jacamo.infra.JaCaMoLauncher)
├── settings.gradle
├── conf/
│   └── eismassimconfig.json  # config da ponte EIS<->MASSim
├── lib/
│   └── eismassim.jar         # eismassim-4.5-jar-with-dependencies copiado
└── src/
    ├── agt/                  # agentes Jason (.asl)
    │   ├── agente_base.asl   # planos comuns a todos
    │   ├── coordenador.asl   # papel social MOISE+ "coordinator"
    │   └── explorador.asl    # papel social MOISE+ "explorer"
    ├── env/                  # artefatos CArtAgO (Java)
    │   └── mapc/
    │       └── QuadroEquipe.java
    ├── org/                  # especificação MOISE+
    │   └── org.xml
    └── java/                 # código Java auxiliar
        └── jason/eis/
            └── EISAdapter.java  # ponte Jason<->EISMASSim
```

## Pré-requisitos

- JDK ≥ 17 (verifique: `java -version`)
- O servidor MASSim 2022 já compilado (em `../massim_2022/`, basta rodar `mvn package` lá uma vez)

## Como rodar

### 1. Suba o servidor MASSim em outro terminal

```bash
cd ../massim_2022
java -jar server/target/server-2022-1.1-jar-with-dependencies.jar \
     -conf server/conf/SampleConfig.json --monitor 8000
```

Servidor escutará em `localhost:12300`. Monitor web em [http://localhost:8000/](http://localhost:8000/).

### 2. Suba o time JaCaMo

```bash
cd mapc2022_pcs5703
./gradlew run
```

A primeira execução baixa o JaCaMo 1.3.0 do Maven (≈2 min). Depois é instantânea.

### 3. Inicie a partida no servidor

No terminal do servidor, pressione **ENTER** quando os 3 agentes do `mapc2022_pcs5703` (e idealmente os 3+ do time adversário) estiverem autenticados.

## Mapeamento Jason ↔ servidor

| Agente Jason (`.jcm`) | Entidade EIS (`eismassimconfig.json`) | Username MASSim |
|---|---|---|
| `coordenador1` | `coordenador1` | `agentA1` |
| `explorador1` | `explorador1` | `agentA2` |
| `explorador2` | `explorador2` | `agentA3` |

A senha de todos é `1` (vem do `SampleConfig.json` do servidor). Para usar o time **B** em vez do **A**, troque `agentA*` por `agentB*` no `eismassimconfig.json`.

## Como o exercício é atendido (mapeamento para o template do relatório)

| Item do enunciado | Onde está no projeto |
|---|---|
| **Item 2** — Análise e especificação do SMA | A definir no relatório, ancorado em [src/org/org.xml](src/org/org.xml) (papéis, missões, normas) |
| **Item 3** — Arquitetura e design do SMA | [mapc2022.jcm](mapc2022.jcm) (visão geral) + [src/org/org.xml](src/org/org.xml) (organização) + [src/env/mapc/QuadroEquipe.java](src/env/mapc/QuadroEquipe.java) (ambiente) |
| **Item 4** — Linguagens e plataforma | Jason (agentes), CArtAgO (ambiente), MOISE+ (org), tudo orquestrado por JaCaMo 1.3.0 |
| **Item 5** — Estratégia para time | A desenvolver: lógica em [src/agt/coordenador.asl](src/agt/coordenador.asl) (escolha de tarefa) e [src/agt/explorador.asl](src/agt/explorador.asl) (movimentação) |
| **Item 6** — Características técnicas | Robustez: tratamento de timeout, recuperação de agentes individuais (a evoluir) |
| **Item 7** — Discussão | Diferencial deste trabalho: uso explícito de MOISE+, ausente em [5] LTI-USP e nos JaCaMo Builders 2020/21 |

## Próximos passos sugeridos

Este esqueleto **conecta, percebe e age**, mas a inteligência ainda é trivial (random walk). Para evoluir, focar em:

1. **Logs/memória de exploração** — `explorador.asl` precisa registrar dispensers, taskboards e goal zones que vir, em coordenadas absolutas relativas à posição inicial. Padrão: ver paper [5] §3.1.
2. **Identificação de companheiros** — quando agentes se vêem, reconhecer-se via posição-espelho. Padrão: ver paper [5] §3.2.
3. **Protocolo de tarefa** — o coordenador escolhe task no taskboard, anuncia no `QuadroEquipe`, agentes que adotam papel `worker` (compatível via `formation-constraints` no org.xml) buscam blocos.
4. **Submissão** — montar pattern e chamar `submit(NomeTask)` numa goal zone.

## Referências consultadas

- Stabile Jr., M.F.; Sichman, J.S. *The LTI-USP Strategy to the 2020/2021 MAPC*. LNAI 12947, 2021. — referência [5] do enunciado.
- Amaral, C.J. et al. *JaCaMo Builders: Team Description for the MAPC 2020/21*. LNAI 12947, 2021. — discutido por usar JaCaMo+CArtAgO mas **sem MOISE+**, gap que este projeto preenche.
- Documentação oficial do cenário: [`../massim_2022/docs/scenario.md`](../massim_2022/docs/scenario.md)
