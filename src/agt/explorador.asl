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
+actionID(ID) : ultimo_action_id(Last) & ID \== Last <-
    -+ultimo_action_id(ID);
    .findall(r(A, R), (lastAction(A) & lastActionResult(R)), LAR);
    .findall(t(S, TS, DL), (step(S) & timestamp(TS) & deadline(DL)), TL);
    .print("[DBGres] ", LAR, " | step/ts/deadline: ", TL);
    !atualizar_posicao;
    !publicar_posicao;
    !relatar_posicao_teste;
    !registrar_descobertas;
    !identificar_companheiros;
    !anunciar_offset_ref;
    !logar_visao;
    !escolher_acao(Acao);
    !executar(Acao);
    acao_concluida.   // libera o perceiveLoop do EIS a consumir o proximo passo
// actionID repetido (mesmo passo reprocessado pela ponte EIS): ignora,
// garantindo UMA acao por passo.
+actionID(_) <- true.


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
 * Converte cada percepcao relativa do step em coordenada absoluta no frame
 * PROPRIO (somando a posicao atual) e guarda como crenca mem_*(...). A
 * publicacao no quadro NAO e feita aqui: ela ocorre em !publicar_mapa_ref,
 * ja re-projetada para o frame de referencia (passo 2), de modo que os
 * mapas dos varios exploradores se fundam.
 *
 * NOMES DE PERCEPT (MAPC 2022, confirmados em docs/eismassim.md):
 *   dispenser -> thing(X,Y,dispenser,Tipo)
 *   goal zone -> goalZone(X,Y)
 *   role zone -> roleZone(X,Y)
 * (NAO existe taskboard nem goal(X,Y) no 2022 - isso era do cenario 2021.)
 */
+!registrar_descobertas : flag_mapear & posicao(PX, PY) <-
    for ( thing(RX, RY, dispenser, Tipo) ) {
        AX = PX + RX; AY = PY + RY;
        if ( not mem_dispenser(AX, AY, Tipo) ) { +mem_dispenser(AX, AY, Tipo); }
    }
    for ( goalZone(RX, RY) ) {
        AX = PX + RX; AY = PY + RY;
        if ( not mem_goalzone(AX, AY) ) { +mem_goalzone(AX, AY); }
    }
    for ( roleZone(RX, RY) ) {
        AX = PX + RX; AY = PY + RY;
        if ( not mem_rolezone(AX, AY) ) { +mem_rolezone(AX, AY); }
    }
    !publicar_mapa_ref.
// flag_mapear desligada (ou sem posicao ainda): nao faz nada.
+!registrar_descobertas <- true.

/*
 * Publica no QuadroEquipe (no frame de REFERENCIA) as descobertas mem_ ainda
 * nao publicadas. So roda quando offset_ref ja e conhecido; converte cada
 * coordenada do frame proprio para o de referencia somando offset_ref. Marca
 * com pub_* para nao republicar. Quando dois exploradores publicam o mesmo
 * ponto fisico, sai a MESMA coordenada de referencia -> a dedup do
 * QuadroEquipe funde os mapas.
 */
+!publicar_mapa_ref : offset_ref(RDX, RDY) <-
    for ( mem_dispenser(AX, AY, Tipo) & not pub_dispenser(AX, AY, Tipo) ) {
        registrar_dispenser(AX + RDX, AY + RDY, Tipo);
        +pub_dispenser(AX, AY, Tipo);
    }
    for ( mem_goalzone(AX, AY) & not pub_goalzone(AX, AY) ) {
        registrar_goal(AX + RDX, AY + RDY);
        +pub_goalzone(AX, AY);
    }
    for ( mem_rolezone(AX, AY) & not pub_rolezone(AX, AY) ) {
        registrar_rolezone(AX + RDX, AY + RDY);
        +pub_rolezone(AX, AY);
    }.
// offset_ref ainda desconhecido: mantem em mem_ e tenta de novo nos proximos passos.
+!publicar_mapa_ref <- true.


/*
 * PASSO 2 (identificacao de companheiros por posicao-espelho) agora e
 * compartilhado: os planos !identificar_companheiros, !publicar_posicao e os
 * handlers de mensagem (avistei_colega/seu_offset) ficam em agente_base.asl,
 * pois tanto exploradores quanto o coordenador participam do alinhamento.
 */


/*
 * Loga os objetos de interesse na visao do agente, no proprio passo.
 * Util para entender o que o agente "ve" enquanto debugamos.
 */
+!logar_visao <-
    .findall(d(X,Y,T), thing(X,Y,dispenser,T), Disp);
    .findall(g(X,Y),   goalZone(X,Y),           Goals);
    .findall(z(X,Y),   roleZone(X,Y),           RZs);
    .length(Disp, ND);
    .length(Goals, NG);
    .length(RZs,  NZ);
    if (ND > 0 | NG > 0 | NZ > 0) {
        .my_name(Eu);
        .print("[", Eu, "] vejo ", ND, " dispenser(s), ",
               NG, " goal zone(s), ", NZ, " role zone(s)");
    }.


/* ===================================================================== */
/* ESCOLHA DE ACAO: ESCAPE POR clear + RANDOM WALK                        */
/* ===================================================================== */

/*
 * Regras auxiliares para decidir o movimento.
 *
 * celula_bloqueada(DX,DY): a celula relativa (DX,DY) tem algo que impede
 *   o agente de entrar (obstaculo, bloco ou outra entidade).
 * direcao_livre(D): existe uma direcao cardinal D cuja celula esta livre.
 * obstaculo_adjacente(DX,DY): ha um obstaculo numa celula cardinal vizinha.
 * energia_ok: energia atual >= energia_minima_seguranca (de agente_base).
 */
celula_bloqueada(DX,DY) :- thing(DX,DY,obstacle,_).
celula_bloqueada(DX,DY) :- thing(DX,DY,block,_).
celula_bloqueada(DX,DY) :- thing(DX,DY,entity,_).

direcao_livre(D)        :- delta(D,DX,DY) & not celula_bloqueada(DX,DY).

obstaculo_adjacente(DX,DY) :- delta(_,DX,DY) & thing(DX,DY,obstacle,_).

energia_ok :- energy(E) & energia_minima_seguranca(Min) & E >= Min.

/*
 * ALVOS CONHECIDOS no FRAME PROPRIO. Refinamento: alem do que o agente viu
 * pessoalmente (mem_*), usa o MAPA COMPARTILHADO (frame de referencia,
 * dispenser_descoberto/goal_descoberta/rolezone_descoberta) convertendo para
 * o frame proprio via offset_ref. Assim um worker pode ir ao dispenser que
 * OUTRO agente achou.
 *   ponto_proprio = ponto_ref - offset_ref
 */
disp_conhecido(T, X, Y) :- mem_dispenser(X, Y, T).
disp_conhecido(T, X, Y) :- dispenser_descoberto(RX, RY, T) & offset_ref(RDX, RDY)
                           & X = RX - RDX & Y = RY - RDY.

goalzone_conhecida(X, Y) :- mem_goalzone(X, Y).
goalzone_conhecida(X, Y) :- goal_descoberta(RX, RY) & offset_ref(RDX, RDY)
                            & X = RX - RDX & Y = RY - RDY.

rolezone_conhecida(X, Y) :- mem_rolezone(X, Y).
rolezone_conhecida(X, Y) :- rolezone_descoberta(RX, RY) & offset_ref(RDX, RDY)
                            & X = RX - RDX & Y = RY - RDY.

/*
 * ANTI-OSCILACAO: a direcao D leva de volta a celula de onde acabei de vir?
 * livre_ok(D): direcao livre que NAO volta atras (preferida na navegacao).
 */
volta_atras(D) :- delta(D, DX, DY) & posicao(X, Y) & pos_anterior(PX, PY)
                  & PX == X + DX & PY == Y + DY.
livre_ok(D)    :- direcao_livre(D) & not volta_atras(D).

/*
 * ESCOLHA DE ACAO (prioridade):
 *   1) Se sou worker e ha task-alvo -> logica do worker (acao_worker).
 *   2) Caso contrario -> exploracao dirigida (que tambem cava obstaculos
 *      se estiver encurralado).
 */
+!escolher_acao(Acao) : sou_worker & tarefa_alvo(N,QX,QY,T) <-
    !acao_worker(N, QX, QY, T, Acao).
+!escolher_acao(Acao) <-
    !explorar(Acao).

/* --------------------------------------------------------------------- */
/* EXPLORACAO DIRIGIDA (cobertura/rendezvous, com anti-oscilacao)        */
/* --------------------------------------------------------------------- */
/*
 * Mantem um RUMO e segue nele enquanto livre e sem voltar atras (cobre
 * mais terreno e favorece encontros). Ao bater/oscilar, sorteia novo rumo,
 * preferindo direcoes que NAO voltam a celula anterior. Encurralado: cava.
 */
+!explorar(move(Dir)) : rumo(Dir) & livre_ok(Dir) <- true.
+!explorar(move(Dir)) : livre_ok(_) <-
    !dir_livre_ok_aleatoria(Dir);  -+rumo(Dir).
+!explorar(move(Dir)) : direcao_livre(_) <-      // so volta atras se nao ha outra
    !dir_livre_aleatoria(Dir);     -+rumo(Dir).
+!explorar(clear(DX,DY)) : obstaculo_adjacente(DX,DY) & energia_ok <-
    .my_name(Eu);
    .print("[", Eu, "] ENCURRALADO; cavando obstaculo em (", DX, ",", DY, ")").
+!explorar(skip) <- true.

+!dir_livre_ok_aleatoria(Dir) <-
    .findall(D, livre_ok(D), L);
    .length(L, N);  .random(R);  I = math.floor(R * N);  .nth(I, L, Dir).
+!dir_livre_aleatoria(Dir) <-
    .findall(D, direcao_livre(D), L);
    .length(L, N);  .random(R);  I = math.floor(R * N);  .nth(I, L, Dir).

/* --------------------------------------------------------------------- */
/* NAVEGACAO GULOSA rumo a um alvo (TX,TY) no frame proprio              */
/* --------------------------------------------------------------------- */
// ha alguma saida -> escolhe direcao (dir_gulosa sempre acha uma); senao explora.
+!mover_rumo(TX, TY, move(Dir)) : direcao_livre(_) & posicao(X, Y) <-
    DX = TX - X;  DY = TY - Y;
    !dir_gulosa(DX, DY, Dir).
+!mover_rumo(_, _, Acao) <-
    !explorar(Acao).

// 1) eixo dominante, livre e sem voltar atras
+!dir_gulosa(DX, DY, e) : DX > 0 & math.abs(DX) >= math.abs(DY) & livre_ok(e) <- true.
+!dir_gulosa(DX, DY, w) : DX < 0 & math.abs(DX) >= math.abs(DY) & livre_ok(w) <- true.
+!dir_gulosa(DX, DY, s) : DY > 0 & math.abs(DY) >  math.abs(DX) & livre_ok(s) <- true.
+!dir_gulosa(DX, DY, n) : DY < 0 & math.abs(DY) >  math.abs(DX) & livre_ok(n) <- true.
// 2) a outra direcao util, livre e sem voltar atras
+!dir_gulosa(DX, _,  e) : DX > 0 & livre_ok(e) <- true.
+!dir_gulosa(DX, _,  w) : DX < 0 & livre_ok(w) <- true.
+!dir_gulosa(_,  DY, s) : DY > 0 & livre_ok(s) <- true.
+!dir_gulosa(_,  DY, n) : DY < 0 & livre_ok(n) <- true.
// 3) qualquer direcao livre sem voltar atras
+!dir_gulosa(_, _, D) : livre_ok(D) <- true.
// 4) ultima opcao: qualquer direcao livre (pode voltar atras) - garante saida
+!dir_gulosa(_, _, D) : direcao_livre(D) <- true.


/* ===================================================================== */
/* PASSO 3: WORKER - BUSCAR BLOCO, LEVAR A GOAL ZONE E SUBMETER           */
/* ===================================================================== */

/*
 * Quando o coordenador anuncia tarefa_alvo(N,QX,QY,T) no QuadroEquipe, o
 * explorador se promove a worker (sou_worker). Daí em diante, acao_worker
 * conduz a maquina de estados a cada passo.
 *
 * Modelo MAPC 2022 (sem accept/taskboard): escolher task -> juntar bloco
 * (request+attach num dispenser) -> levar a uma goal zone -> submit.
 *
 * LIMITACOES conhecidas (single-block, papeis padrao):
 *  - so tratamos tasks de 1 bloco com requisito em celula cardinal
 *    adjacente (|QX|+|QY|=1), pois o worker NAO tem a acao rotate.
 *  - para o bloco cair na posicao (QX,QY) exigida, aproximamos o dispenser
 *    pelo lado certo (ficar na celula dispenser-(QX,QY)) e pedir/anexar
 *    na direcao (QX,QY).
 *  - role default nao faz request/attach/submit; por isso e preciso achar
 *    um role zone e adoptar "worker" antes.
 */
@reagir_tarefa_alvo
+tarefa_alvo(N, QX, QY, T) : flag_virar_worker & not sou_worker <-
    .my_name(Eu);
    .print("[WORKER] ", Eu, " assumiu task ", N, " (bloco ", T, " em ", QX, ",", QY, ")");
    +sou_worker.

// mapeia um deslocamento cardinal (QX,QY) para a direcao correspondente
dir_de_delta(QX, QY, Dir) :- delta(Dir, QX, QY).

/* ---- FASE A: adotar o papel de cenario "worker" (precisa de role zone) ---- */
// estou sobre um role zone -> adopt(worker)
+!acao_worker(_, _, _, _, adopt(worker)) : not role(worker) & roleZone(0,0) <- true.
// conheco um role zone (proprio ou do mapa compartilhado) -> navego ate ele
+!acao_worker(_, _, _, _, Acao) : not role(worker) & rolezone_conhecida(TX,TY) <-
    !mover_rumo(TX, TY, Acao).
// nao conheco role zone -> exploro para achar um
+!acao_worker(_, _, _, _, Acao) : not role(worker) <-
    !explorar(Acao).

/* ---- FASE B: sou worker, ainda sem bloco -> buscar/anexar ---- */
// o dispenser do tipo esta exatamente na direcao requerida (QX,QY) -> request
+!acao_worker(_, QX, QY, T, request(Dir))
    : role(worker) & not carregando(_) & not pedi_bloco(_)
      & dir_de_delta(QX, QY, Dir) & thing(QX, QY, dispenser, T)
    <- +pedi_bloco(Dir).
// pedi e o bloco apareceu em (QX,QY) -> attach
+!acao_worker(_, QX, QY, T, attach(Dir))
    : role(worker) & not carregando(_) & pedi_bloco(Dir) & thing(QX, QY, block, _)
    <- -pedi_bloco(Dir); +carregando(T);
       .my_name(Eu); .print("[WORKER] ", Eu, " anexou bloco ", T, " em (", QX, ",", QY, ")").
// pedi mas o bloco ainda nao apareceu -> espera
+!acao_worker(_, _, _, _, skip) : role(worker) & not carregando(_) & pedi_bloco(_) <- true.
// conheco um dispenser do tipo (proprio ou compartilhado) -> navego para a
// celula que poe o dispenser em (QX,QY)
+!acao_worker(_, QX, QY, T, Acao)
    : role(worker) & not carregando(_) & disp_conhecido(T, DXa, DYa)
    <- TXa = DXa - QX;  TYa = DYa - QY;
       !mover_rumo(TXa, TYa, Acao).
// nao conheco dispenser do tipo -> exploro
+!acao_worker(_, _, _, _, Acao) : role(worker) & not carregando(_) <-
    !explorar(Acao).

/* ---- FASE C: sou worker, com bloco -> levar a goal zone e submeter ---- */
// estou numa goal zone -> submit
+!acao_worker(N, _, _, _, submit(N))
    : role(worker) & carregando(_) & goalZone(0,0) & flag_submeter
    <- .my_name(Eu); .print("[WORKER] ", Eu, " em goal zone - submetendo ", N).
// conheco uma goal zone (propria ou compartilhada) -> navego ate ela
+!acao_worker(_, _, _, _, Acao) : role(worker) & carregando(_) & goalzone_conhecida(TX,TY) <-
    !mover_rumo(TX, TY, Acao).
// nao conheco goal zone -> exploro
+!acao_worker(_, _, _, _, Acao) : role(worker) & carregando(_) <-
    !explorar(Acao).

// fallback geral
+!acao_worker(_, _, _, _, skip) <- true.
