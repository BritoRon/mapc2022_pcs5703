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
 *   1. Faz um log resumido do que esta vendo.
 *   2. Decide um movimento aleatorio entre n/s/e/w.
 *   3. Executa via !executar.
 *
 * Esta e a versao mais ingenua possivel. As iteracoes seguintes
 * substituem random_walk por uma estrategia inteligente.
 */
+actionID(_) <-
    !logar_visao;
    !escolher_acao(Acao);
    !executar(Acao).


/*
 * Loga os objetos de interesse na visao do agente, no proprio passo.
 * Util para entender o que o agente "ve" enquanto debugamos.
 */
+!logar_visao <-
    .findall(d(X,Y,T), thing(X,Y,dispenser,T), Disp);
    .findall(b(X,Y),   goal(X,Y),               Goals);
    .findall(t(X,Y),   taskboard(X,Y),          Tbds);
    if (Disp \== [] | Goals \== [] | Tbds \== []) {
        .my_name(Eu);
        .print("[",Eu,"] vejo ",
            .length(Disp,_)," dispenser(s), ",
            .length(Goals,_)," goal(s), ",
            .length(Tbds,_)," taskboard(s)");
    }
    true.


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
