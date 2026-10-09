"""
conftest.py de pytest.

Por qué existe: los tests hacen 'from main import app', y pytest solo agrega
a sys.path el directorio del archivo de test (app/tests/), no app/.
La presencia de este archivo hace que pytest inserte app/ en sys.path
(comportamiento documentado de pytest en modo "prepend"), permitiendo
importar el modulo main. Sin el, el job CI falla con ModuleNotFoundError
(exit code 2) aunque el codigo de la app este correcto.
"""
