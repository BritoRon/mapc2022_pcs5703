package mapc;

import cartago.Artifact;
import cartago.OPERATION;
import cartago.INTERNAL_OPERATION;

import eis.EnvironmentInterfaceStandard;
import eis.PerceptUpdate;
import eis.iilang.Action;
import eis.iilang.Function;
import eis.iilang.Identifier;
import eis.iilang.Numeral;
import eis.iilang.Parameter;
import eis.iilang.ParameterList;
import eis.iilang.Percept;

import jason.asSyntax.ASSyntax;
import jason.asSyntax.ListTerm;
import jason.asSyntax.ListTermImpl;
import jason.asSyntax.Structure;
import jason.asSyntax.Term;

import massim.eismassim.EnvironmentInterface;

import java.util.Collection;
import java.util.Map;

/**
 * EISArtifact - wrapper CArtAgO da biblioteca EISMASSim.
 *
 * <p><b>Por que existe este artefato?</b><br>
 * O JaCaMo 1.3.0 nao suporta declarar um <code>jason.environment.Environment</code>
 * customizado direto no arquivo .jcm (so aceita CArtAgO como ambiente). Para
 * conectarmos os agentes ao servidor MASSim 2022, precisamos envolver a EISMASSim
 * num artefato CArtAgO. Este e o padrao recomendado pelo time LFC/MLFC nos
 * papers do MAPC 2019-2021 (veja <i>EISAccess</i> em LNAI 12947).</p>
 *
 * <p><b>Como o tabuleiro fica montado:</b>
 * <ul>
 *   <li>Cada agente Jason (e.g. <code>explorador1</code>) tem seu <b>proprio</b>
 *       artefato <code>EISArtifact("explorador1")</code>, focado por ele via
 *       <code>focus: equipe.eis_explorador1</code> no .jcm.</li>
 *   <li>O <b>primeiro</b> artefato a ser instanciado faz o trabalho pesado:
 *       cria a <code>EnvironmentInterface</code> singleton, le
 *       <code>conf/eismassimconfig.json</code> e abre as conexoes TCP com o
 *       servidor MASSim na porta 12300.</li>
 *   <li>A partir dai, cada artefato roda uma INTERNAL_OPERATION
 *       <code>perceiveLoop</code> que bloqueia em
 *       <code>ei.getPercepts(entityName)</code> aguardando o proximo step do
 *       servidor; quando chega novo step, traduz cada IILang Percept em
 *       observable property CArtAgO. O agente Jason ve isso como crencas
 *       (<code>+thing(0,1,dispenser,b0)</code>, etc).</li>
 *   <li>Para AGIR no servidor, o agente Jason chama uma operacao do artefato:
 *       <code>move(n)</code>, <code>attach(s)</code>, <code>submit(t1)</code>,
 *       etc. As operacoes traduzem para <code>eis.iilang.Action</code> e
 *       chamam <code>ei.performAction(...)</code>.</li>
 * </ul>
 *
 * <p><b>Observacao didatica:</b> esta classe e o item central da dimensao
 * AMBIENTE (item 3 do template do relatorio). E aqui que mora a "ponte" entre
 * a representacao logica do mundo (crencas Jason) e o ambiente externo
 * (servidor MASSim 2022 via TCP/JSON).</p>
 */
public class EISArtifact extends Artifact {

    /*
     * SINGLETON DA EnvironmentInterface.
     *
     * A biblioteca EISMASSim foi projetada como um objeto unico que gerencia
     * todas as entidades do time. Por isso usamos uma referencia estatica
     * compartilhada por todos os artefatos. O lock garante que so um artefato
     * inicialize a EI - os demais reutilizam a mesma instancia.
     */
    private static volatile EnvironmentInterfaceStandard ei;
    private static final Object initLock = new Object();

    /** Nome da entidade EIS associada a este artefato (e ao agente Jason). */
    private String entityName;

    /**
     * Inicializacao do artefato. Recebe como parametro o nome da entidade EIS
     * que este artefato vai controlar - tipicamente igual ao nome do agente
     * Jason que faz focus nele (e.g. "explorador1").
     */
    void init(String entityName) {
        this.entityName = entityName;
        ensureEIStarted();
        // Dispara o 1o ciclo de percepcao. Cada ciclo e UMA operacao interna
        // que se re-agenda (ver perceiveStep) - assim as observable properties
        // sao commitadas/propagadas aos agentes a cada passo.
        execInternalOp("perceiveStep");
    }

    /**
     * Inicializa a EnvironmentInterface, idempotente. So o primeiro artefato
     * a chamar isto faz o trabalho - os demais ja encontram <code>ei != null</code>.
     *
     * Este metodo:
     *   1. Le conf/eismassimconfig.json para descobrir a quem se conectar;
     *   2. Abre TCP com o servidor MASSim;
     *   3. Para CADA entidade declarada no JSON, registra um agente EIS de
     *      mesmo nome e associa-os 1:1 (a convencao adotada pelo esqueleto
     *      oficial dos organizadores do MAPC).
     */
    private static void ensureEIStarted() {
        if (ei != null) return;
        synchronized (initLock) {
            if (ei != null) return;

            System.out.println("[EISArtifact] Inicializando EISMASSim a partir de conf/eismassimconfig.json...");
            EnvironmentInterface envIf = new EnvironmentInterface("conf/eismassimconfig.json");

            try {
                envIf.start();

                for (String e : envIf.getEntities()) {
                    System.out.println("[EISArtifact] Registrando entidade EIS: " + e);
                    envIf.registerAgent(e);
                    envIf.associateEntity(e, e);
                }
            } catch (Exception ex) {
                throw new RuntimeException(
                    "Falha ao iniciar EISMASSim. Servidor MASSim esta de pe na :12300?", ex);
            }

            ei = envIf;
        }
    }

    /* ================================================================== */
    /* LOOP DE PERCEPCAO                                                   */
    /* ================================================================== */

    /**
     * Loop principal de percepcao - roda numa thread propria do artefato.
     *
     * <p>Como o eismassimconfig.json esta com <code>scheduling: true</code>,
     * a chamada <code>ei.getPercepts(entityName)</code> BLOQUEIA ate o proximo
     * step do servidor (ou ate o timeout de 4000ms). Isso significa que este
     * loop e naturalmente cadenciado pelo ritmo da simulacao - nao precisa de
     * sleep/polling explicito.</p>
     */
    /**
     * UM ciclo de percepcao. Bloqueia em getPercepts ate o proximo step do
     * servidor (scheduling=true), traduz os percepts em observable properties
     * e entao SE RE-AGENDA via execInternalOp.
     *
     * <p><b>Por que uma operacao por ciclo (e nao um while(true))?</b><br>
     * No CArtAgO, as alteracoes de observable property feitas durante uma
     * operacao so sao COMMITADAS e propagadas aos agentes observadores quando
     * a operacao TERMINA. Um while(true) que nunca retorna jamais commitava as
     * obs properties - os agentes nunca recebiam +step/+actionID como crenca.
     * Reagendando a cada passo, cada ciclo termina e propaga suas mudancas.</p>
     */
    @INTERNAL_OPERATION
    void perceiveStep() {
        try {
            Collection<String> entities = ei.getAssociatedEntities(entityName);
            Map<String, PerceptUpdate> perMap =
                ei.getPercepts(entityName, entities.toArray(new String[0]));

            for (String ent : entities) {
                PerceptUpdate update = perMap.get(ent);
                if (update == null) continue;

                // Primeiro removemos as percepcoes que sairam de cena
                for (Percept p : update.getDeleteList()) {
                    removePercept(p);
                }
                // Depois adicionamos as novas
                for (Percept p : update.getAddList()) {
                    addPercept(p);
                }
            }
        } catch (Exception ex) {
            // Servidor caiu / encerrando: loga e NAO re-agenda (encerra o loop).
            System.err.println("[EISArtifact:" + entityName + "] perceiveStep encerrado: "
                               + ex.getMessage());
            return;
        }
        // Re-agenda o proximo ciclo como uma NOVA operacao interna, garantindo
        // que as obs properties deste ciclo sejam commitadas antes da proxima.
        execInternalOp("perceiveStep");
    }

    /**
     * Adiciona um Percept como uma nova observable property no artefato.
     * Cada parametro do Percept e convertido para um tipo Java/Jason que o
     * CArtAgO sabe propagar ao agente como crenca.
     */
    private void addPercept(Percept p) {
        Object[] params = convertParams(p.getParameters());
        try {
            defineObsProperty(p.getName(), params);
        } catch (Exception e) {
            // [DEBUG] revela falhas de defineObsProperty (antes engolidas).
            // Mostra o tipo de cada param para diagnosticar incompatibilidade.
            StringBuilder tipos = new StringBuilder();
            for (Object o : params) {
                tipos.append(o == null ? "null" : o.getClass().getSimpleName());
                tipos.append("=").append(o).append(" ");
            }
            System.out.println("[ADDFAIL:" + entityName + "] " + p.getName()
                + "/" + params.length + " : " + e.getClass().getSimpleName()
                + " : " + e.getMessage() + " | params: " + tipos);
        }
    }

    /**
     * Remove a observable property correspondente a um Percept que saiu da
     * lista de percepcoes do agente.
     */
    private void removePercept(Percept p) {
        Object[] params = convertParams(p.getParameters());
        try {
            removeObsPropertyByTemplate(p.getName(), params);
        } catch (Exception ignored) {
        }
    }

    /* ================================================================== */
    /* CONVERSAO DE PARAMETROS IILang -> Java/Jason                        */
    /* ================================================================== */

    /**
     * Converte uma lista de parametros IILang num array Object para uso com
     * <code>defineObsProperty</code> e <code>removeObsPropertyByTemplate</code>.
     */
    private static Object[] convertParams(java.util.List<Parameter> ps) {
        Object[] arr = new Object[ps.size()];
        for (int i = 0; i < ps.size(); i++) {
            arr[i] = paramToObject(ps.get(i));
        }
        return arr;
    }

    /**
     * Converte um Parameter IILang num objeto Java compativel com CArtAgO.
     * <ul>
     *   <li><b>Numeral</b> -> Integer (se inteiro) ou Double</li>
     *   <li><b>Identifier</b> -> Term Jason (atomo se comeca com minuscula,
     *       String caso contrario)</li>
     *   <li><b>ParameterList</b> -> ListTerm Jason</li>
     *   <li><b>Function</b> -> Structure Jason (e.g. req(0,1,b0))</li>
     * </ul>
     */
    private static Object paramToObject(Parameter p) {
        if (p instanceof Numeral) {
            Number n = ((Numeral) p).getValue();
            double d = n.doubleValue();
            if (d == Math.floor(d) && !Double.isInfinite(d)) {
                return (int) d;
            }
            return d;
        } else if (p instanceof Identifier) {
            String s = ((Identifier) p).getValue();
            try {
                if (!s.isEmpty() && !Character.isUpperCase(s.charAt(0))) {
                    return ASSyntax.parseTerm(s);
                }
            } catch (Exception ignored) {
            }
            return s;
        } else if (p instanceof ParameterList) {
            ListTerm list = new ListTermImpl();
            ListTerm tail = list;
            for (Parameter pp : (ParameterList) p) {
                tail = tail.append(paramToTerm(pp));
            }
            return list;
        } else if (p instanceof Function) {
            Function f = (Function) p;
            Structure s = ASSyntax.createStructure(f.getName());
            for (Parameter pp : f.getParameters()) {
                s.addTerm(paramToTerm(pp));
            }
            return s;
        }
        return p.toString();
    }

    /**
     * Versao auxiliar de {@link #paramToObject} que SEMPRE retorna um Term
     * Jason (necessario quando estamos dentro de listas ou estruturas, onde
     * Numbers/Strings precisam virar NumberTerm/StringTerm).
     */
    private static Term paramToTerm(Parameter p) {
        Object o = paramToObject(p);
        if (o instanceof Term) return (Term) o;
        if (o instanceof Number) return ASSyntax.createNumber(((Number) o).doubleValue());
        if (o instanceof String) return ASSyntax.createString((String) o);
        return ASSyntax.createString(o.toString());
    }

    /* ================================================================== */
    /* OPERACOES DE ACAO - chamaveis pelos agentes Jason                   */
    /* ================================================================== */

    /*
     * Cada acao do cenario MASSim 2022 tem uma OPERATION correspondente.
     * Os agentes invocam diretamente pelo nome (e.g. <code>move(n)</code> num
     * plano .asl) - o CArtAgO roteia para o artefato focado de mesma assinatura.
     *
     * Atencao aos tipos: o servidor MASSim aceita as direcoes como ATOMOS
     * (n, s, e, w), nao como strings entre aspas. Em CArtAgO o tipo equivalente
     * e String (CArtAgO converte automaticamente para Identifier IILang).
     *
     * Lista completa das acoes do cenario 2022 (ver docs/scenario.md):
     *   skip                    - nao fazer nada neste step
     *   move(D)                 - andar 1 celula na direcao D
     *   attach(D)               - prender bloco adjacente em D ao agente
     *   detach(D)               - soltar bloco em D
     *   rotate(D)               - rotacionar self+blocos em torno do agente
     *   connect(Ag, X, Y)       - conectar bloco em (X,Y) ao bloco do agente Ag
     *   disconnect(X1,Y1,X2,Y2) - separar dois blocos conectados
     *   request(D)              - pedir bloco do dispenser na direcao D
     *   submit(NomeTask)        - submeter task quando em goal zone
     *   clear(X,Y)              - limpar (consome energia, abre caminho)
     *   accept(NomeTask)        - aceitar task estando proximo a um taskboard
     *   adopt(NomeRoleMASSim)   - adotar role do cenario (worker, digger, etc)
     *   survey_dispenser(X,Y)   - mapear distancia ate dispenser do tipo
     *   survey_zone(X,Y)        - mapear distancia ate goal/role zone
     */

    @OPERATION public void skip()                    { send("skip"); }
    @OPERATION public void move(String d)            { send("move", new Identifier(d)); }
    @OPERATION public void attach(String d)          { send("attach", new Identifier(d)); }
    @OPERATION public void detach(String d)          { send("detach", new Identifier(d)); }
    @OPERATION public void rotate(String d)          { send("rotate", new Identifier(d)); }
    @OPERATION public void request(String d)         { send("request", new Identifier(d)); }
    @OPERATION public void submit(String task)       { send("submit", new Identifier(task)); }
    @OPERATION public void accept(String task)       { send("accept", new Identifier(task)); }
    @OPERATION public void adopt(String role)        { send("adopt", new Identifier(role)); }

    @OPERATION public void connect(String ag, int x, int y) {
        send("connect", new Identifier(ag), new Numeral(x), new Numeral(y));
    }

    @OPERATION public void disconnect(int x1, int y1, int x2, int y2) {
        send("disconnect", new Numeral(x1), new Numeral(y1), new Numeral(x2), new Numeral(y2));
    }

    @OPERATION public void clear(int x, int y) {
        send("clear", new Numeral(x), new Numeral(y));
    }

    @OPERATION public void survey(int x, int y) {
        send("survey", new Numeral(x), new Numeral(y));
    }

    /**
     * Helper interno: envia uma acao ao servidor MASSim via EISMASSim.
     * Toda OPERATION acima delega aqui.
     */
    private void send(String name, Parameter... params) {
        try {
            ei.performAction(entityName, new Action(name, params));
        } catch (Exception e) {
            // Servidor pode rejeitar acao depois do deadline ou em estado
            // invalido. Logar mas nao explodir o agente.
            System.err.println("[EISArtifact:" + entityName + "] Acao "
                + name + " falhou: " + e.getMessage());
        }
    }
}
