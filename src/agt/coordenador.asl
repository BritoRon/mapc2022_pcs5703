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
 * Estrategia para o esqueleto: o coordenador apenas registra as tarefas
 * disponiveis e manda skip. Logica real (escolher e aceitar tarefa)
 * pode ser desenvolvida nas iteracoes seguintes.
 */
+actionID(_) <-
    // Coleta todas as tarefas disponiveis para inspecao
    .findall(task(N,D,R,Req), task(N,D,R,Req), Tarefas);
    .length(Tarefas, Qtd);
    if (Qtd > 0) {
        .print(Qtd, " tarefa(s) disponivel(eis). TODO: escolher uma.");
    }
    !executar(skip).
