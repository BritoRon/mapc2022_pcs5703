/*
 * coordenador.asl
 *
 * Agente que adota o papel social MOISE+ "coordinator" no grupo do time.
 *
 * Funcao no esqueleto:
 *   - Comeca o esquema social "completar_tarefa" (so o coordenador pode
 *     comecar, pois e o unico vinculado a m_coordenar).
 *   - Le periodicamente as tarefas disponiveis no servidor e (no futuro)
 *     decide qual aceitar - ainda nao decide, apenas loga.
 *   - Em cada passo executa "skip" para nao perder o passo enquanto a
 *     logica nao esta pronta. ESSA E A LOGICA QUE VOCE VAI PRECISAR
 *     EXPANDIR PARA O EXERCICIO.
 *
 * Item 5 do relatorio (Estrategia para time de agentes): aqui dentro vai
 * a politica de "qual task aceitar". Sugestoes para evoluir:
 *   - Priorizar tasks pequenas (1 ou 2 blocos) - LTI-USP §3.4
 *   - Considerar a deadline e o reward decay - GOAL-DTU 2021
 *   - Iniciar leilao entre os workers para ver quem esta mais perto
 *     dos blocos necessarios - JaCaMo Builders §4.1
 */

{ include("agente_base.asl") }


/* ===================================================================== */
/* META INICIAL                                                           */
/* ===================================================================== */

/*
 * Quando o agente "nasce", ele dispara essa meta. O grupo time_a e o
 * esquema "completar_tarefa" precisam estar prontos antes disso. O
 * jacamo cuida de criar grupo e esquema porque foram declarados no .jcm.
 *
 * Aqui pedimos para o agente se comprometer com a missao m_coordenar.
 * A norma "n_coord" no org.xml DIZ que ele tem essa obrigacao - como
 * incluimos org-obedient.asl, o proprio agente ja vai cumprir por conta
 * propria. Esse !iniciar e mais um "hello" para verificar que tudo subiu.
 */
!iniciar.

+!iniciar <-
    .my_name(Eu);
    .print("Coordenador ", Eu, " inicializado.");
    .print("Aguardando inicio da simulacao no servidor MASSim ...").


/* ===================================================================== */
/* OBRIGACAO RESPONDIDA: COMPROMETER-SE COM A MISSAO m_coordenar          */
/* ===================================================================== */

/*
 * O org-obedient.asl ja tem um plano generico que faz commitMission
 * automaticamente quando uma obrigacao chega. Mas se quisermos
 * customizar, podemos sobrepor:
 *
 *     +obligation(Ag, _What, committed(Ag, M, Esq), _Until)
 *         : .my_name(Ag) <-
 *           .print("Recebi obrigacao de me comprometer com missao ", M);
 *           commitMission(M).
 *
 * Comentado porque o org-obedient.asl ja faz - deixado de exemplo.
 */


/* ===================================================================== */
/* CICLO DE PASSO (placeholder)                                           */
/* ===================================================================== */

/*
 * Uma vez que a simulacao comecou, o servidor envia em cada passo um
 * conjunto de percepcoes incluindo "actionID(I)". Quando o agente percebe
 * o novo actionID, ele tem ate "deadline" milissegundos para retornar uma
 * acao. Se nao mandar nada, o servidor conta como "skip".
 *
 * O coordenador atualiza sua posicao e roda o ciclo de decisao. So pode
 * sair UMA acao por step, entao o ciclo OU aceita uma tarefa OU manda skip.
 */
+actionID(ID) : ultimo_action_id(Last) & ID \== Last <-
    -+ultimo_action_id(ID);
    !atualizar_posicao;
    !publicar_posicao;
    !identificar_companheiros;   // coordenador parado serve de "marco" de frame
    !anunciar_offset_ref;
    !ciclo_coordenador;
    acao_concluida.   // libera o perceiveLoop do EIS a consumir o proximo passo
// actionID repetido (mesmo passo reprocessado pela ponte EIS): ignora.
+actionID(_) <- true.


/* ===================================================================== */
/* PASSO 3 (lado coordenador): ESCOLHER E ANUNCIAR A TASK-ALVO            */
/* ===================================================================== */

/*
 * Modelo MAPC 2022: nao ha accept nem taskboard. O coordenador apenas
 * ESCOLHE uma task ativa e a anuncia (tarefa_alvo) no QuadroEquipe; os
 * workers cuidam de juntar o bloco e submeter numa goal zone.
 *
 * O coordenador e estacionario: sempre executa skip; a decisao (selecionar
 * a task) e o efeito do seu passo.
 */
+!ciclo_coordenador <-
    !selecionar_tarefa;
    !executar(skip).

/*
 * Escolhe (se preciso) a melhor task de UM bloco com requisito em celula
 * cardinal adjacente (|QX|+|QY|=1, unica viavel sem rotate) e a anuncia.
 * Criterio: maior reward (.max ordena cand(R,...) pelo 1o arg).
 */
+!selecionar_tarefa : flag_selecionar_tarefa & precisa_selecionar <-
    // So tasks de 1 bloco, com requisito cardinal adjacente, E cujo tipo de
    // bloco JA tem dispenser descoberto (senao a task e incompletavel agora).
    .findall(cand(R, N, QX, QY, T),
             ( task(N, _, R, [req(QX, QY, T)]) & (math.abs(QX) + math.abs(QY)) == 1
               & tem_dispenser(T) ),
             L);
    if (L \== []) {
        .max(L, cand(_, NB, QXB, QYB, TB));
        .print("[COORD] task-alvo: ", NB, " | bloco ", TB, " em (", QXB, ",", QYB, ")");
        anunciar_tarefa_alvo(NB, QXB, QYB, TB);
    }.
// nada a (re)selecionar agora, ou nenhuma task viavel: nao faz nada.
+!selecionar_tarefa <- true.

/*
 * Precisa selecionar quando ainda nao ha alvo, ou quando o alvo atual
 * expirou (nao consta mais entre as tasks ativas).
 */
precisa_selecionar :- not tarefa_alvo(_, _, _, _).
precisa_selecionar :- tarefa_alvo(N, _, _, _) & not task(N, _, _, _).

/*
 * Existe dispenser do tipo T no mapa compartilhado? Robusto ao tipo do bloco
 * vir como ATOMO (b2, na task) ou STRING ("b2", em dispenser_descoberto, que
 * passou pela operacao Java registrar_dispenser(String)).
 */
tem_dispenser(T) :- dispenser_descoberto(_, _, T).
tem_dispenser(T) :- .term2string(T, TS) & dispenser_descoberto(_, _, TS).

// [DEBUG passo 3] loga cada task nova (uma vez) com tamanho e requisitos,
// para sabermos se aparecem tasks de 1 bloco com requisito cardinal.
+task(N, D, R, Reqs) : not ja_vi_task(N) <-
    +ja_vi_task(N);
    .length(Reqs, Tam);
    .print("[TASKINFO] ", N, " size=", Tam, " reward=", R, " reqs=", Reqs).
