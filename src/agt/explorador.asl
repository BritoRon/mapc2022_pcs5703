/*
 * explorador.asl
 *
 * Agente que adota o papel social MOISE+ "explorer" no grupo do time.
 *
 * Funcao no esqueleto:
 *   - Recebe percepcoes do servidor e registra dispensers, taskboards e
 *     goal zones que enxergar (ainda em logging - a memoria persistente
 *     fica para a proxima iteracao).
 *   - Em cada passo escolhe um movimento simples (random walk).
 *
 * Para evoluir (item 5 do relatorio):
 *   - Substituir random walk pelo Spanning Tree Coverage (JaCaMo Builders
 *     §4.1) - eles mediram +70% de cobertura comparado ao espiral.
 *   - Compartilhar descobertas via o artefato `quadro` - escrever
 *     dispenser_descoberto(X,Y,Tipo) na blackboard quando ver um.
 *   - Trocar de papel para "worker" quando coletar 2 blocos.
 *     Isso e modelado pela compatibility from="explorer" to="worker"
 *     no org.xml e basta um adoptRole("worker") na hora certa.
 */

{ include("agente_base.asl") }


/* ===================================================================== */
/* META INICIAL                                                           */
/* ===================================================================== */

!iniciar.

+!iniciar <-
    .my_name(Eu);
    .print("Explorador ", Eu, " inicializado. Esperando simulacao comecar...").


/* ===================================================================== */
/* TRATAMENTO DE PERCEPCOES DO MUNDO                                      */
/* ===================================================================== */

/*
 * Quando o servidor MASSim manda thing(X,Y,Tipo,Detalhe), o EISAdapter
 * cria automaticamente uma crenca thing(X,Y,Tipo,Detalhe). Aqui podemos
 * reagir a percepcoes especificas. Mas CUIDADO:
 *
 *   1. Os percepts sao RELATIVOS a posicao do agente naquele step
 *      (ver docs/scenario.md -> "absolutePosition: false").
 *   2. As crencas sao adicionadas E REMOVIDAS pelo EISAdapter ao
 *      sincronizar com o estado atual - isso significa que +thing(...)
 *      dispara muitas vezes por passo. Nao gere log para cada uma.
 *
 * Para o esqueleto, vamos apenas logar UMA VEZ POR PASSO um resumo dos
 * objetos interessantes. Fazemos isso no plano +actionID abaixo.
 */


/* ===================================================================== */
/* CICLO DE PASSO                                                         */
/* ===================================================================== */

/*
 * Cada vez que o servidor anuncia o novo actionID, o agente:
 *   1. Atualiza sua posicao absoluta (passo 1, em agente_base.asl).
 *   2. Registra no mapa/quadro o que vir (passo 1).
 *   3. Tenta identificar companheiros a vista (passo 2).
 *   4. Loga um resumo do que enxerga.
 *   5. Decide a acao do passo e executa.
 *
 * O baseline ainda usa random walk em escolher_acao. As iteracoes
 * seguintes substituem isso por uma estrategia de cobertura inteligente.
 */
+actionID(ID) <-
    .findall(r(A, R), (lastAction(A) & lastActionResult(R)), LAR);
    .print("[DBGres] ultima acao/resultado: ", LAR);
    !atualizar_posicao;
    !relatar_posicao_teste;
    !registrar_descobertas;
    !identificar_companheiros;
    !logar_visao;
    !escolher_acao(Acao);
    !executar(Acao).


/*
 * [INSTRUMENTACAO DE TESTE - passo 1] Publica a posicao no quadro para
 * imprimir o heartbeat via System.out (os .print do agente sao engolidos
 * em ambiente headless). Remover quando nao precisar mais observar.
 */
+!relatar_posicao_teste : flag_mapear & posicao(X, Y) <-
    .my_name(Eu);
    relatar_posicao(Eu, X, Y).
+!relatar_posicao_teste <- true.


/* ===================================================================== */
/* PASSO 1: MEMORIA DE MAPA (RELATIVO -> ABSOLUTO) + PUBLICACAO           */
/* ===================================================================== */

/*
 * Converte cada percepcao relativa do step em coordenada absoluta (somando
 * a posicao atual do agente) e:
 *   - guarda localmente como crenca mem_*(...) para nao reprocessar,
 *   - publica no QuadroEquipe (registrar_*) para o time inteiro enxergar.
 *
 * A dedup acontece em dois niveis: aqui (not mem_*) evita reprocessar; e no
 * QuadroEquipe.java (Sets) evita observable properties duplicadas.
 *
 * NOTA: thing(X,Y,dispenser,Tipo), goal(X,Y) e taskboard(X,Y) sao os nomes
 * de percept que o esqueleto assume. Conferir com ../massim_2022/docs/
 * scenario.md - se o cenario usar outro nome (ex: goalZone), ajustar aqui.
 */
+!registrar_descobertas : flag_mapear & posicao(PX, PY) <-
    for ( thing(RX, RY, dispenser, Tipo) ) {
        AX = PX + RX; AY = PY + RY;
        if ( not mem_dispenser(AX, AY, Tipo) ) {
            +mem_dispenser(AX, AY, Tipo);
            registrar_dispenser(AX, AY, Tipo);
        }
    }
    for ( goal(RX, RY) ) {
        AX = PX + RX; AY = PY + RY;
        if ( not mem_goal(AX, AY) ) {
            +mem_goal(AX, AY);
            registrar_goal(AX, AY);
        }
    }
    for ( taskboard(RX, RY) ) {
        AX = PX + RX; AY = PY + RY;
        if ( not mem_taskboard(AX, AY) ) {
            +mem_taskboard(AX, AY);
            registrar_taskboard(AX, AY);
        }
    }.
// flag_mapear desligada (ou sem posicao ainda): nao faz nada.
+!registrar_descobertas <- true.


/* ===================================================================== */
/* PASSO 2: IDENTIFICACAO DE COMPANHEIROS (POSICAO-ESPELHO)               */
/* ===================================================================== */

/*
 * Quando dois agentes do mesmo time se enxergam, cada um ve o outro como
 * thing(RX,RY,entity,MeuTime). Como a visao e simetrica, da pra inferir a
 * posicao-espelho e ALINHAR os referenciais (origens (0,0) distintas) dos
 * dois agentes - condicao necessaria para fundir os mapas publicados no
 * QuadroEquipe.
 *
 * TODO passo 2 (ver LTI-USP §3.2): casar candidatos por posicao-espelho,
 *   trocar mensagens .send para confirmar identidade e calcular o offset
 *   (DX,DY) entre os referenciais; depois reprojetar as crencas mem_ e o quadro.
 */
+!identificar_companheiros : flag_identificar & team(MeuTime) <-
    // Candidatos: entidades do MEU time visiveis neste step (coords relativas).
    .findall(ent(RX, RY), thing(RX, RY, entity, MeuTime), Colegas);
    // TODO passo 2: descartar a si mesmo, casar por posicao-espelho,
    //   confirmar via .send e calcular o offset entre os referenciais.
    .length(Colegas, _).
// flag_identificar desligada: nao faz nada (default seguro).
+!identificar_companheiros <- true.


/*
 * Loga os objetos de interesse na visao do agente, no proprio passo.
 * Util para entender o que o agente "ve" enquanto debugamos.
 */
+!logar_visao <-
    .findall(d(X,Y,T), thing(X,Y,dispenser,T), Disp);
    .findall(g(X,Y),   goal(X,Y),               Goals);
    .findall(t(X,Y),   taskboard(X,Y),          Tbds);
    // .length precisa ser chamado como acao (resultado numa variavel);
    // NAO pode ser embutido como termo dentro do .print.
    .length(Disp, ND);
    .length(Goals, NG);
    .length(Tbds, NT);
    if (ND > 0 | NG > 0 | NT > 0) {
        .my_name(Eu);
        .print("[", Eu, "] vejo ", ND, " dispenser(s), ",
               NG, " goal(s), ", NT, " taskboard(s)");
    }.


/*
 * Escolhe uma direcao aleatoria. .random/1 retorna float em [0,1).
 *
 * IMPORTANTE: o servidor aceita os codigos de direcao "n", "s", "e", "w".
 * Eles devem ser passados como atomos Jason (sem aspas) - por isso
 * escrevemos move(n), nao move("n").
 */
+!escolher_acao(move(D)) <-
    .random(R);
    if (R < 0.25)      { D = n; }
    elif (R < 0.50)    { D = s; }
    elif (R < 0.75)    { D = e; }
    else               { D = w; }.


/* ===================================================================== */
/* PASSO 3 (lado worker): REAGIR AO ANUNCIO DE TAREFA E VIRAR WORKER      */
/* ===================================================================== */

/*
 * Quando o coordenador chama anunciar_tarefa(Task) no QuadroEquipe, a
 * observable property tarefa_atual muda e TODOS os agentes focados recebem
 * +tarefa_atual(Task). O explorador reage promovendo-se a worker.
 *
 * A compatibility from="explorer" to="worker" no org.xml e o que PERMITE
 * acumular o papel social; o adopt(...) de cenario MASSim e o que muda as
 * acoes fisicas disponiveis no jogo.
 */
@reagir_anuncio_tarefa
+tarefa_atual(Task) : Task \== "nenhuma" & flag_virar_worker <-
    .my_name(Eu);
    .print("[", Eu, "] time aceitou '", Task, "'. Promovendo-me a worker.");
    !virar_worker(Task).

+!virar_worker(Task) : flag_virar_worker <-
    // TODO passo 3:
    //   adoptRole(worker);          // papel SOCIAL MOISE+ (compatibility)
    //   !executar(adopt(worker));   // papel de CENARIO MASSim (acoes fisicas)
    //   depois: ler os blocos exigidos pela Task (crenca task(Task,_,_,Req))
    //   e ir buscar/anexar cada um via request/attach. Ver QuadroEquipe
    //   para descobrir dispensers ja mapeados (dispenser_descoberto/3).
    !montar_estrutura(Task).
+!virar_worker(_) <- true.


/* ===================================================================== */
/* PASSO 4: MONTAR ESTRUTURA E SUBMETER NA GOAL ZONE                      */
/* ===================================================================== */

/*
 * Depois de coletar os blocos, o worker precisa posiciona-los no pattern
 * pedido pela task (acoes attach/rotate/connect entre workers) e, estando
 * numa goal zone, executar submit(Task).
 */
+!montar_estrutura(Task) : flag_virar_worker <-
    // TODO passo 4a: buscar blocos nos dispensers e conecta-los no formato
    //   exigido (req(DX,DY,Tipo) dentro da crenca task). Coordenacao entre
    //   workers via QuadroEquipe / link worker<->worker do org.xml.
    !submeter_tarefa(Task).
+!montar_estrutura(_) <- true.

+!submeter_tarefa(Task) : flag_submeter & em_goal_zone <-
    .my_name(Eu);
    .print("[", Eu, "] em goal zone - submetendo '", Task, "'.");
    !executar(submit(Task)).
// Ainda nao esta na goal zone (ou flag desligada): TODO navegar ate ela.
+!submeter_tarefa(_) <- true.

/*
 * Verdadeiro quando o agente esta sobre uma celula de goal zone. Como as
 * percepcoes sao relativas, a celula do proprio agente e (0,0).
 * TODO passo 4b: confirmar o nome do percept de goal zone com scenario.md.
 */
em_goal_zone :- goal(0, 0).
