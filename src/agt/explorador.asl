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
    !reset_pos_submit;
    !diag_worker;
    !escolher_acao(Acao);
    !executar(Acao);
    acao_concluida.   
// libera o perceiveLoop do EIS a consumir o proximo passo
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
disp_conhecido(T, X, Y) :- dispenser_descoberto(RX, RY, DT) & mesmo_tipo(T, DT)
                           & offset_ref(RDX, RDY) & X = RX - RDX & Y = RY - RDY.
// tipos iguais, robusto a ATOMO (task) vs STRING (mapa compartilhado via Java)
mesmo_tipo(T, T).
mesmo_tipo(T, DT) :- .term2string(T, DT).

// igualdade de tipo SIMETRICA: converte AMBOS os lados a string e compara.
// Necessaria porque o tipo da tarefa_alvo chega como STRING "b1" (veio do
// coordenador via CArtAgO), mas o tipo no percept thing(...) e o ATOMO b1.
// Sem isso, a unificacao crua "b1" \= b1 e a visao nunca casa o dispenser.
tipo_igual(A, B) :- .term2string(A, S) & .term2string(B, S).

/*
 * ALVOS VISIVEIS (na visao atual, em coords RELATIVAS). Navegar por estes e
 * robusto ao grid TOROIDAL - a percepcao relativa e sempre o caminho curto
 * real, ao contrario das coordenadas absolutas gravadas (que divergem no toro).
 * (0,0) e a propria celula, entao excluimos.
 */
rolezone_visivel(RX, RY)    :- roleZone(RX, RY) & (RX \== 0 | RY \== 0).
goalzone_visivel(GX, GY)    :- goalZone(GX, GY) & (GX \== 0 | GY \== 0).
dispenser_visivel(T, DX, DY) :- thing(DX, DY, dispenser, DT) & tipo_igual(T, DT).

/*
 * Move UM passo rumo a um alvo dado em coordenada RELATIVA (RX,RY) a partir de
 * mim (que sou (0,0)). Reusa o dir_gulosa: o "delta ate o alvo" e o proprio
 * (RX,RY). Sem saida livre -> explora.
 */
+!mover_rel(RX, RY, move(Dir)) : direcao_livre(_) <- !dir_gulosa(RX, RY, Dir).
+!mover_rel(_, _, Acao) <- !explorar(Acao).

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
 * ALVO MAIS PROXIMO (Manhattan) de cada tipo, no frame proprio. Reduz passos
 * desperdiçados em relacao a pegar um alvo arbitrario. So sao chamados quando
 * o respectivo *_conhecida/_conhecido ja vale (a lista nunca e vazia).
 */
+!alvo_rolezone_proximo(X, Y) : posicao(PX, PY) <-
    .findall(d(D, RX, RY),
             (rolezone_conhecida(RX, RY) & D = math.abs(RX-PX) + math.abs(RY-PY)), L);
    .min(L, d(_, X, Y)).
+!alvo_disp_proximo(T, X, Y) : posicao(PX, PY) <-
    .findall(d(D, DX, DY),
             (disp_conhecido(T, DX, DY) & D = math.abs(DX-PX) + math.abs(DY-PY)), L);
    .min(L, d(_, X, Y)).
+!alvo_goalzone_proximo(X, Y) : posicao(PX, PY) <-
    .findall(d(D, GX, GY),
             (goalzone_conhecida(GX, GY) & D = math.abs(GX-PX) + math.abs(GY-PY)), L);
    .min(L, d(_, X, Y)).

/*
 * ESCOLHA DE ACAO (prioridade):
 *   1) Se sou worker e ha task-alvo -> logica do worker (acao_worker).
 *   2) Caso contrario -> exploracao dirigida (que tambem cava obstaculos
 *      se estiver encurralado).
 */
+!escolher_acao(Acao) : sou_worker & tarefa_alvo(N,QX,QY,_) & tipo_alvo(T) <-
    !acao_worker(N, QX, QY, T, Acao).
+!escolher_acao(Acao) <-
    !explorar(Acao).

/* --------------------------------------------------------------------- */
/* EXPLORACAO DIRIGIDA (cobertura/rendezvous, com anti-oscilacao)        */
/* --------------------------------------------------------------------- */
/*
 * EXPLORACAO POR COBERTURA (varredura serpentina / "lawnmower").
 *
 * Cada explorador segue uma direcao PRIMARIA por cob_leg passos, da UM passo
 * PERPENDICULAR, reverte a primaria e repete - varrendo faixas de forma
 * sistematica (cobre muito mais que random walk, entao os workers topam com
 * dispensers/zonas com confiabilidade). Robusto ao grid TOROIDAL: conta passos
 * RELATIVOS, nao usa coordenadas absolutas. Os dois exploradores comecam com
 * orientacoes diferentes para cobrir mais. Obstaculos: vira/desvia.
 */
cob_leg(20).   // perna longa: varre faixas largas (melhor cobertura)   // comprimento da perna da serpentina

// Init preguicoso do estado de cobertura (na 1a vez que explora).
+!explorar(Acao) : not cob_dir(_) <-
    .my_name(Eu);  !init_cobertura(Eu);  !explorar(Acao).
+!init_cobertura(explorador1) <- +cob_dir(e); +cob_perp(s); ?cob_leg(N); +cob_passos(N).
+!init_cobertura(explorador2) <- +cob_dir(s); +cob_perp(e); ?cob_leg(N); +cob_passos(N).
+!init_cobertura(_)           <- +cob_dir(n); +cob_perp(e); ?cob_leg(N); +cob_passos(N).

// Segue a direcao primaria enquanto livre e ainda ha passos na perna.
+!explorar(move(D)) : cob_dir(D) & cob_passos(N) & N > 0 & direcao_livre(D) <-
    -+cob_passos(N-1).
// Fim da perna (N=0) OU primaria bloqueada -> passo PERPENDICULAR (se livre),
// reverte a primaria e reinicia a contagem da perna.
+!explorar(move(P)) : cob_perp(P) & direcao_livre(P) & cob_dir(D)
                      & (cob_passos(0) | not direcao_livre(D)) <-
    !reverter_dir(D);  ?cob_leg(N);  -+cob_passos(N).
// Primaria e perpendicular bloqueadas -> desvia por qualquer direcao livre.
+!explorar(move(Dir)) : direcao_livre(_) <-
    !dir_livre_aleatoria(Dir).

+!reverter_dir(e) <- -+cob_dir(w).
+!reverter_dir(w) <- -+cob_dir(e).
+!reverter_dir(s) <- -+cob_dir(n).
+!reverter_dir(n) <- -+cob_dir(s).
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
    // T chega como STRING "b1" (veio do coordenador via CArtAgO). Convertemos
    // ao ATOMO b1 (parse via .term2string com 1o arg livre) e guardamos em
    // tipo_alvo, para casar por unificacao pura com thing(...,dispenser,b1).
    .term2string(Tatom, T);  -+tipo_alvo(Tatom);
    .print("[WORKER] ", Eu, " assumiu task ", N, " (bloco ", Tatom, " em ", QX, ",", QY, ")");
    +sou_worker.

// mapeia um deslocamento cardinal (QX,QY) para a direcao correspondente
dir_de_delta(QX, QY, Dir) :- delta(Dir, QX, QY).

// quantos passos esperar o bloco aparecer apos um request antes de desistir
// (evita deadlock se o request falhar no servidor e o bloco nunca vier)
max_espera_bloco(5).

/* ---- INSTRUMENTACAO DA COLETA (so imprime quando ja sou worker) ----
 * Mostra, a cada passo, o estado da maquina de coleta para diagnosticar
 * ONDE a fase B/C trava: papel adotado, task-alvo, dispensers do tipo
 * VISIVEIS (e onde), zonas visiveis, pedido pendente, espera e carga.   */
+!diag_worker : sou_worker & tarefa_alvo(N, QX, QY, _) & tipo_alvo(T) <-
    .my_name(Eu);
    .findall(d(DX,DY), dispenser_visivel(T, DX, DY), DispV);
    .findall(k(KX,KY), disp_conhecido(T, KX, KY),    DispK);
    .findall(x, rolezone_visivel(_,_),   RZv);  .length(RZv, NRZv);
    .findall(x, goalzone_visivel(_,_),   GZv);  .length(GZv, NGZv);
    .findall(x, rolezone_conhecida(_,_), RZk);  .length(RZk, NRZk);
    .findall(x, goalzone_conhecida(_,_), GZk);  .length(GZk, NGZk);
    .findall(p(P),   role(P),        Papeis);
    .findall(pb(PD), pedi_bloco(PD),  PB);
    .findall(ew(K),  espera_bloco(K), Esp);
    .findall(cg(CT), carregando(CT),  Carga);
    .print("[DIAGW] ", Eu, " papeis=", Papeis, " task=", N,
           " req=(", QX, ",", QY, ") T=", T,
           " | disp_vis=", DispV, " disp_conh=", DispK,
           " | rz_vis=", NRZv, " rz_conh=", NRZk, " gz_vis=", NGZv, " gz_conh=", NGZk,
           " | pedi=", PB, " espera=", Esp, " carrega=", Carga).
+!diag_worker <- true.

/* ---- RESET POS-SUBMIT ----------------------------------------------------
 * Apos um submit BEM-SUCEDIDO (lastActionResult success no passo anterior), a
 * tarefa esta concluida: liberamos o estado de coleta (carregando/pedido) e o
 * papel social de worker (sou_worker/tipo_alvo), para o agente voltar a explorar
 * e poder assumir uma NOVA tarefa quando o coordenador anunciar outra. Sem isto,
 * o worker fica preso reenviando submit na mesma goal zone.                    */
+!reset_pos_submit
    : sou_worker & carregando(_) & lastAction(submit) & lastActionResult(success) <-
    .my_name(Eu);
    .print("[WORKER] ", Eu, " task concluida (submit ok) - liberando estado p/ nova tarefa");
    .abolish(carregando(_));
    .abolish(pedi_bloco(_));
    .abolish(espera_bloco(_));
    .abolish(tipo_alvo(_));
    -sou_worker.
+!reset_pos_submit <- true.

/* ---- FASE A: adotar o papel de cenario "worker" (precisa de role zone) ---- */
// estou sobre um role zone -> adopt(worker)
+!acao_worker(_, _, _, _, adopt(worker)) : not role(worker) & roleZone(0,0) <- true.
// VEJO um role zone -> navego por VISAO (relativo, robusto ao toro)
+!acao_worker(_, _, _, _, Acao) : not role(worker) & rolezone_visivel(RX, RY) <-
    !mover_rel(RX, RY, Acao).
// nao vejo, mas CONHECO um role zone (mapa) -> rumo ao mais proximo ate avista-lo;
// ao entrar na visao (raio 5), o plano acima (por VISAO) assume a aproximacao final.
+!acao_worker(_, _, _, _, Acao) : not role(worker) & rolezone_conhecida(_, _) <-
    !alvo_rolezone_proximo(TX, TY);  !mover_rumo(TX, TY, Acao).
// nem vejo nem conheco um role zone -> exploro ate um entrar na visao
+!acao_worker(_, _, _, _, Acao) : not role(worker) <-
    !explorar(Acao).

/* ---- FASE B: sou worker, ainda sem bloco -> buscar/anexar ---- */
// o dispenser do tipo esta exatamente na direcao requerida (QX,QY) -> request
+!acao_worker(_, QX, QY, T, request(Dir))
    : role(worker) & not carregando(_) & not pedi_bloco(_)
      & dir_de_delta(QX, QY, Dir) & thing(QX, QY, dispenser, DT) & tipo_igual(T, DT)
    <- +pedi_bloco(Dir);  +espera_bloco(0).
// pedi e o bloco apareceu em (QX,QY) -> attach
+!acao_worker(_, QX, QY, T, attach(Dir))
    : role(worker) & not carregando(_) & pedi_bloco(Dir) & thing(QX, QY, block, _)
    <- -pedi_bloco(Dir); .abolish(espera_bloco(_)); +carregando(T);
       .my_name(Eu); .print("[WORKER] ", Eu, " anexou bloco ", T, " em (", QX, ",", QY, ")").
// pedi mas o bloco ainda nao apareceu, dentro do limite -> conta e espera
+!acao_worker(_, _, _, _, skip)
    : role(worker) & not carregando(_) & pedi_bloco(_)
      & espera_bloco(K) & max_espera_bloco(Max) & K < Max
    <- Kp = K + 1;  -+espera_bloco(Kp).
// estourou o limite de espera -> desiste do pedido e volta a buscar
// (destrava o deadlock: request pode ter falhado no servidor)
+!acao_worker(N, QX, QY, T, Acao)
    : role(worker) & not carregando(_) & pedi_bloco(_)
      & espera_bloco(K) & max_espera_bloco(Max) & K >= Max
    <- .my_name(Eu);
       .print("[WORKER] ", Eu, " timeout esperando bloco (", K, " passos) - desiste do pedido e retoma busca");
       .abolish(pedi_bloco(_));  .abolish(espera_bloco(_));
       !acao_worker(N, QX, QY, T, Acao).
// VEJO um dispenser do tipo -> me posiciono (por VISAO) na celula que poe o
// dispenser em (QX,QY): se ele esta em (DX,DY) relativo, ando rumo a (DX-QX,DY-QY).
+!acao_worker(_, QX, QY, T, Acao)
    : role(worker) & not carregando(_) & not pedi_bloco(_) & dispenser_visivel(T, DX, DY)
    <- RX = DX - QX;  RY = DY - QY;
       !mover_rel(RX, RY, Acao).
// nao vejo, mas CONHECO um dispenser do tipo (mapa) -> rumo ao mais proximo ate
// avista-lo; ao entrar na visao, o plano por VISAO acima faz o posicionamento fino.
+!acao_worker(_, _, _, T, Acao)
    : role(worker) & not carregando(_) & not pedi_bloco(_) & disp_conhecido(T, _, _)
    <- !alvo_disp_proximo(T, TX, TY);  !mover_rumo(TX, TY, Acao).
// nem vejo nem conheco um dispenser do tipo -> exploro ate um entrar na visao
+!acao_worker(_, _, _, _, Acao) : role(worker) & not carregando(_) <-
    !explorar(Acao).

/* ---- FASE C: sou worker, com bloco -> levar a goal zone e submeter ---- */
// estou numa goal zone -> submit
+!acao_worker(N, _, _, _, submit(N))
    : role(worker) & carregando(_) & goalZone(0,0) & flag_submeter
    <- .my_name(Eu); .print("[WORKER] ", Eu, " em goal zone - submetendo ", N).
// VEJO uma goal zone -> navego por VISAO (relativo, robusto ao toro)
+!acao_worker(_, _, _, _, Acao) : role(worker) & carregando(_) & goalzone_visivel(GX, GY) <-
    !mover_rel(GX, GY, Acao).
// nao vejo, mas CONHECO uma goal zone (mapa) -> rumo a mais proxima ate avista-la
+!acao_worker(_, _, _, _, Acao) : role(worker) & carregando(_) & goalzone_conhecida(_, _) <-
    !alvo_goalzone_proximo(TX, TY);  !mover_rumo(TX, TY, Acao).
// nem vejo nem conheco uma goal zone -> exploro ate uma entrar na visao
+!acao_worker(_, _, _, _, Acao) : role(worker) & carregando(_) <-
    !explorar(Acao).

// fallback geral
+!acao_worker(_, _, _, _, skip) <- true.
