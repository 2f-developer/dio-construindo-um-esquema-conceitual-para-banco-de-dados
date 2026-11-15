-- Oficina mecânica: controle de ordens de serviço (OS).
-- MySQL 8.0.16+.

DROP DATABASE IF EXISTS oficina;
CREATE DATABASE oficina CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE oficina;

CREATE TABLE cliente (
  id         INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  nome       VARCHAR(120) NOT NULL,
  documento  VARCHAR(14) NOT NULL UNIQUE COMMENT 'CPF (11) ou CNPJ (14 dígitos)',
  telefone   VARCHAR(20) NOT NULL,
  email      VARCHAR(120),
  CONSTRAINT ck_cliente_documento CHECK (documento REGEXP '^([0-9]{11}|[0-9]{14})$')
);

CREATE TABLE veiculo (
  id          INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  cliente_id  INT UNSIGNED NOT NULL,
  placa       CHAR(7) NOT NULL UNIQUE,
  marca       VARCHAR(40) NOT NULL,
  modelo      VARCHAR(60) NOT NULL,
  ano         SMALLINT UNSIGNED NOT NULL,
  -- Placa antiga (ABC1234) ou Mercosul (ABC1D23).
  CONSTRAINT ck_veiculo_placa CHECK (placa REGEXP '^[A-Z]{3}[0-9][A-Z0-9][0-9]{2}$'),
  CONSTRAINT ck_veiculo_ano CHECK (ano BETWEEN 1950 AND 2100),
  FOREIGN KEY (cliente_id) REFERENCES cliente (id)
);

CREATE TABLE equipe (
  id    INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  nome  VARCHAR(60) NOT NULL UNIQUE
);

CREATE TABLE mecanico (
  codigo         INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  equipe_id      INT UNSIGNED NOT NULL,
  nome           VARCHAR(120) NOT NULL,
  endereco       VARCHAR(200) NOT NULL,
  especialidade  VARCHAR(60) NOT NULL,
  FOREIGN KEY (equipe_id) REFERENCES equipe (id)
);

-- Tabela de referência de mão de obra: o preço de cada serviço.
CREATE TABLE servico (
  id               INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  descricao        VARCHAR(120) NOT NULL UNIQUE,
  valor_mao_obra   DECIMAL(10, 2) NOT NULL,
  CONSTRAINT ck_servico_valor CHECK (valor_mao_obra > 0)
);

CREATE TABLE peca (
  id         INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  descricao  VARCHAR(120) NOT NULL,
  valor      DECIMAL(10, 2) NOT NULL,
  CONSTRAINT ck_peca_valor CHECK (valor > 0)
);

CREATE TABLE ordem_servico (
  numero              INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  veiculo_id          INT UNSIGNED NOT NULL,
  -- A equipe é designada por OS: o mesmo carro pode voltar meses depois e cair em outra equipe.
  equipe_id           INT UNSIGNED NOT NULL,
  tipo                ENUM('conserto', 'revisao') NOT NULL,
  status              ENUM('em_avaliacao', 'aguardando_autorizacao', 'autorizada', 'em_execucao', 'concluida', 'cancelada')
                      NOT NULL DEFAULT 'em_avaliacao',
  data_emissao        DATE NOT NULL,
  data_entrega        DATE NOT NULL COMMENT 'Data de entrega prometida ao cliente',
  autorizada_em       DATETIME COMMENT 'Quando o cliente autorizou a execução',
  data_conclusao      DATE,
  CONSTRAINT ck_os_entrega CHECK (data_entrega >= data_emissao),
  CONSTRAINT ck_os_conclusao CHECK (data_conclusao IS NULL OR data_conclusao >= data_emissao),
  -- Não se executa nem se conclui serviço sem autorização do cliente.
  CONSTRAINT ck_os_autorizacao CHECK (status NOT IN ('autorizada', 'em_execucao', 'concluida') OR autorizada_em IS NOT NULL),
  CONSTRAINT ck_os_concluida CHECK ((status = 'concluida') = (data_conclusao IS NOT NULL)),
  FOREIGN KEY (veiculo_id) REFERENCES veiculo (id),
  FOREIGN KEY (equipe_id) REFERENCES equipe (id)
);

-- Serviços da OS. O valor é copiado da tabela de referência no momento em que entra
-- na OS, para que um reajuste na tabela não altere orçamentos já feitos.
CREATE TABLE os_servico (
  os_numero       INT UNSIGNED,
  servico_id      INT UNSIGNED,
  quantidade      TINYINT UNSIGNED NOT NULL DEFAULT 1,
  valor_unitario  DECIMAL(10, 2) NOT NULL,
  PRIMARY KEY (os_numero, servico_id),
  CONSTRAINT ck_os_servico_qtd CHECK (quantidade > 0),
  FOREIGN KEY (os_numero) REFERENCES ordem_servico (numero) ON DELETE CASCADE,
  FOREIGN KEY (servico_id) REFERENCES servico (id)
);

CREATE TABLE os_peca (
  os_numero       INT UNSIGNED,
  peca_id         INT UNSIGNED,
  quantidade      SMALLINT UNSIGNED NOT NULL DEFAULT 1,
  valor_unitario  DECIMAL(10, 2) NOT NULL,
  PRIMARY KEY (os_numero, peca_id),
  CONSTRAINT ck_os_peca_qtd CHECK (quantidade > 0),
  FOREIGN KEY (os_numero) REFERENCES ordem_servico (numero) ON DELETE CASCADE,
  FOREIGN KEY (peca_id) REFERENCES peca (id)
);

DELIMITER $$

-- Valor do serviço vem da tabela de referência de mão de obra.
CREATE TRIGGER trg_os_servico_valor BEFORE INSERT ON os_servico
FOR EACH ROW
BEGIN
  SET NEW.valor_unitario = (SELECT valor_mao_obra FROM servico WHERE id = NEW.servico_id);
END$$

CREATE TRIGGER trg_os_peca_valor BEFORE INSERT ON os_peca
FOR EACH ROW
BEGIN
  SET NEW.valor_unitario = (SELECT valor FROM peca WHERE id = NEW.peca_id);
END$$

-- A mesma equipe que avaliou executa: depois da autorização, a equipe não muda,
-- e o orçamento autorizado também não.
CREATE TRIGGER trg_os_equipe_fixa BEFORE UPDATE ON ordem_servico
FOR EACH ROW
BEGIN
  IF OLD.autorizada_em IS NOT NULL AND NEW.equipe_id <> OLD.equipe_id THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A equipe não muda depois que o cliente autoriza a OS.';
  END IF;
END$$

CREATE PROCEDURE bloquear_se_autorizada(IN os INT UNSIGNED)
BEGIN
  IF (SELECT autorizada_em FROM ordem_servico WHERE numero = os) IS NOT NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Orçamento autorizado: não é possível alterar serviços ou peças.';
  END IF;
END$$

CREATE TRIGGER trg_os_servico_bloqueio BEFORE INSERT ON os_servico
FOR EACH ROW FOLLOWS trg_os_servico_valor
BEGIN
  CALL bloquear_se_autorizada(NEW.os_numero);
END$$

CREATE TRIGGER trg_os_peca_bloqueio BEFORE INSERT ON os_peca
FOR EACH ROW FOLLOWS trg_os_peca_valor
BEGIN
  CALL bloquear_se_autorizada(NEW.os_numero);
END$$

DELIMITER ;

-- O valor da OS é derivado: mão de obra + peças.
CREATE VIEW vw_ordem_servico AS
SELECT os.numero,
       os.status,
       os.tipo,
       os.data_emissao,
       os.data_entrega,
       os.data_conclusao,
       os.veiculo_id,
       os.equipe_id,
       COALESCE(s.total, 0) AS valor_servicos,
       COALESCE(p.total, 0) AS valor_pecas,
       COALESCE(s.total, 0) + COALESCE(p.total, 0) AS valor_total
FROM ordem_servico os
LEFT JOIN (SELECT os_numero, SUM(quantidade * valor_unitario) AS total FROM os_servico GROUP BY os_numero) s
       ON s.os_numero = os.numero
LEFT JOIN (SELECT os_numero, SUM(quantidade * valor_unitario) AS total FROM os_peca GROUP BY os_numero) p
       ON p.os_numero = os.numero;
